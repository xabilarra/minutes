import Foundation
import MinutesCapture
import MinutesCore
import os

/// Transcribes finished recordings one at a time with Groq and writes the transcript files.
///
/// A meeting's CAF tracks are converted to `yo.m4a` / `ellos.m4a` and deleted only after the
/// transcript has been written, so a failed meeting can always be retried.
actor TranscriptionPipeline {
    struct Status: Equatable, Sendable {
        var queued = 0
        var active: String?
        var failed = 0
    }

    enum PipelineError: LocalizedError {
        case missingAPIKey
        case exportMismatch(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return String(localized: "Falta la clave de Groq. Añádela en la ventana de Minutes o desde el menú (Configurar clave de Groq…).")
            case .exportMismatch(let file):
                return String(localized: "El archivo \(file) exportado no coincide con la duración grabada; se ha conservado el audio original.")
            }
        }
    }

    static let chunkConcurrency = 3
    /// Chunks whose loudest 0.5 s window is quieter than this are not sent (saves cost, avoids hallucinations).
    static let silenceThresholdDB = -50.0

    private let root: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let languageProvider: @Sendable () -> String?
    private let makeClient: @Sendable (String) -> GroqClient
    private let exportFinalAudio: @Sendable (URL, URL) throws -> Void
    private let onStatus: @Sendable (Status) -> Void
    private let onFinished: @Sendable (URL, String?) -> Void
    private var queue: [URL] = []
    private var isDraining = false
    private var status = Status()
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "transcription")

    /// - Parameters:
    ///   - makeClient: builds the Groq client for an API key (tests inject a fake transport).
    ///   - exportFinalAudio: converts a CAF track to its final m4a (tests inject failures).
    init(
        root: URL,
        apiKeyProvider: @escaping @Sendable () -> String?,
        languageProvider: @escaping @Sendable () -> String? = { nil },
        makeClient: @escaping @Sendable (String) -> GroqClient = { GroqClient(apiKey: $0) },
        exportFinalAudio: @escaping @Sendable (URL, URL) throws -> Void = { try AudioFileTools.exportM4A(from: $0, to: $1) },
        onStatus: @escaping @Sendable (Status) -> Void,
        onFinished: @escaping @Sendable (URL, String?) -> Void
    ) {
        self.root = root
        self.apiKeyProvider = apiKeyProvider
        self.languageProvider = languageProvider
        self.makeClient = makeClient
        self.exportFinalAudio = exportFinalAudio
        self.onStatus = onStatus
        self.onFinished = onFinished
    }

    func enqueue(_ folder: URL) {
        guard !queue.contains(folder), status.active != folder.lastPathComponent else { return }
        queue.append(folder)
        publish()
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    /// Re-queues meetings left pending or interrupted by a previous run.
    func resumePending() {
        for folder in meetingFolders() {
            guard let metadata = try? MetadataStore.read(from: folder) else { continue }
            if metadata.transcription.state == .pending || metadata.transcription.state == .transcribing {
                enqueue(folder)
            }
        }
        refreshFailedCount()
    }

    func retryFailed() {
        for folder in meetingFolders() {
            guard let metadata = try? MetadataStore.read(from: folder),
                  metadata.transcription.state == .failed
            else { continue }
            enqueue(folder)
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            status.active = folder.lastPathComponent
            publish()
            let failure = await process(folder)
            status.active = nil
            refreshFailedCount()
            onFinished(folder, failure)
        }
        isDraining = false
        publish()
    }

    /// Returns nil on success or the error message on failure (also stored in meta.json).
    private func process(_ folder: URL) async -> String? {
        guard var metadata = try? MetadataStore.read(from: folder) else {
            return String(localized: "No se puede leer \(MeetingFile.metadata.rawValue) en \(folder.lastPathComponent).")
        }
        // nil lets Whisper detect the language; read once so a meeting uses one language throughout.
        let language = languageProvider()
        let storedLanguage = language ?? TranscriptionLanguage.automatic
        metadata.transcription = TranscriptionStatus(
            state: .transcribing, model: GroqClient.defaultModel, language: storedLanguage)
        try? MetadataStore.write(metadata, to: folder)

        let workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Minutes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        do {
            guard let apiKey = apiKeyProvider(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineError.missingAPIKey
            }
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let client = makeClient(apiKey)
            let cache = ChunkCache(folder: folder, language: storedLanguage)
            let me = try await transcribeTrack(
                Self.audioSource(.micRaw, .micAudio, in: folder), speaker: .me, language: language, client: client,
                workDirectory: workDirectory, cache: cache)
            let them = try await transcribeTrack(
                Self.audioSource(.systemRaw, .systemAudio, in: folder), speaker: .them, language: language, client: client,
                workDirectory: workDirectory, cache: cache)
            let segments = TranscriptAssembler.assemble(me: me, them: them)

            // Raw tracks are deleted last: any failure before this point leaves everything retryable.
            try exportVerifiedAudio(in: folder)
            metadata.transcription = TranscriptionStatus(
                state: .done, model: GroqClient.defaultModel, language: storedLanguage, completedAt: Date())
            try TranscriptRenderer.markdown(segments, metadata: metadata)
                .write(to: folder.appending(path: MeetingFile.transcriptMarkdown.rawValue), atomically: true, encoding: .utf8)
            try TranscriptRenderer.json(segments, metadata: metadata)
                .write(to: folder.appending(path: MeetingFile.transcriptJSON.rawValue), options: .atomic)
            try MetadataStore.write(metadata, to: folder)
            removeRawAudio(in: folder)
            cache.remove()
            logger.info("Transcribed \(folder.lastPathComponent, privacy: .private(mask: .hash)): \(segments.count) segments")
            return nil
        } catch {
            let message = error.localizedDescription
            metadata.transcription = TranscriptionStatus(
                state: .failed, model: GroqClient.defaultModel, language: storedLanguage, error: message)
            try? MetadataStore.write(metadata, to: folder)
            logger.error("Transcription failed for \(folder.lastPathComponent, privacy: .private(mask: .hash)): \(message, privacy: .private)")
            return message
        }
    }

    /// The recorded CAF, or the final m4a when an earlier run already converted the track.
    private static func audioSource(_ raw: MeetingFile, _ final: MeetingFile, in folder: URL) -> URL? {
        [raw, final]
            .map { folder.appending(path: $0.rawValue) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func transcribeTrack(
        _ source: URL?, speaker: Speaker, language: String?, client: GroqClient, workDirectory: URL, cache: ChunkCache
    ) async throws -> [TranscriptSegment] {
        guard let url = source else { return [] }
        let chunks = ChunkPlan.chunks(totalDuration: try AudioFileTools.duration(of: url))
        var results: [Int: [TranscriptSegment]] = [:]
        try await withThrowingTaskGroup(of: (Int, [TranscriptSegment]).self) { group in
            var inFlight = 0
            for chunk in chunks {
                if inFlight >= Self.chunkConcurrency, let (index, segments) = try await group.next() {
                    results[index] = segments
                    inFlight -= 1
                }
                if let cached = cache.segments(speaker: speaker, chunk: chunk) {
                    results[chunk.index] = cached
                    continue
                }
                group.addTask {
                    let (index, segments) = try await Self.transcribeChunk(
                        chunk, of: url, speaker: speaker, language: language, client: client, workDirectory: workDirectory)
                    cache.store(segments, speaker: speaker, chunk: chunk)
                    return (index, segments)
                }
                inFlight += 1
            }
            for try await (index, segments) in group {
                results[index] = segments
            }
        }
        return chunks.flatMap { results[$0.index] ?? [] }
    }

    private static func transcribeChunk(
        _ chunk: AudioChunk, of url: URL, speaker: Speaker, language: String?, client: GroqClient, workDirectory: URL
    ) async throws -> (Int, [TranscriptSegment]) {
        let level = try AudioFileTools.peakWindowLevelDB(of: url, start: chunk.start, duration: chunk.duration)
        guard level > silenceThresholdDB else { return (chunk.index, []) }
        let chunkURL = workDirectory.appending(path: "\(speaker.rawValue)-\(chunk.index).m4a")
        try AudioFileTools.exportM4A(from: url, to: chunkURL, start: chunk.start, duration: chunk.duration)
        defer { try? FileManager.default.removeItem(at: chunkURL) }
        let raw = try await client.transcribe(fileURL: chunkURL, language: language)
        let segments = TranscriptAssembler.segments(from: raw, chunkStart: chunk.start, speaker: speaker)
        // A level that cannot be read keeps the segment: losing speech is worse than keeping a guess.
        return (chunk.index, segments.filter { (try? isAudible($0, in: url)) ?? true })
    }

    /// Whisper invents text ("Gracias.") over silence. Calibrated on a real Meet test: invented
    /// segments peaked at -57…-65 dB, faint real speech at -43 dB, normal speech at -24…-30 dB;
    /// -50 dB leaves about 7 dB of margin on each side.
    static let segmentSilenceThresholdDB = -50.0

    private static func isAudible(_ segment: TranscriptSegment, in url: URL) throws -> Bool {
        let duration = max(segment.end - segment.start, 0.5)
        return try AudioFileTools.peakWindowLevelDB(of: url, start: segment.start, duration: duration)
            > segmentSilenceThresholdDB
    }

    private static let tracks: [(raw: MeetingFile, final: MeetingFile)] = [(.micRaw, .micAudio), (.systemRaw, .systemAudio)]

    /// Converts every CAF track to its final m4a and checks the durations match. Deletes nothing.
    private func exportVerifiedAudio(in folder: URL) throws {
        for track in Self.tracks {
            let rawURL = folder.appending(path: track.raw.rawValue)
            guard FileManager.default.fileExists(atPath: rawURL.path) else { continue }
            let finalURL = folder.appending(path: track.final.rawValue)
            try exportFinalAudio(rawURL, finalURL)
            let rawDuration = try AudioFileTools.duration(of: rawURL)
            let finalDuration = try AudioFileTools.duration(of: finalURL)
            guard abs(rawDuration - finalDuration) < 1.0 else {
                throw PipelineError.exportMismatch(track.final.rawValue)
            }
        }
    }

    /// Called only after the transcript and meta.json (state done) are written.
    private func removeRawAudio(in folder: URL) {
        for track in Self.tracks {
            try? FileManager.default.removeItem(at: folder.appending(path: track.raw.rawValue))
        }
    }

    private func meetingFolders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func refreshFailedCount() {
        status.failed = meetingFolders().filter {
            (try? MetadataStore.read(from: $0))?.transcription.state == .failed
        }.count
        publish()
    }

    private func publish() {
        status.queued = queue.count
        onStatus(status)
    }
}

/// Transcribed chunks kept in the meeting folder until the transcript is written, so a retry
/// (after Groq's hourly limit, a network failure or a quit) only sends the audio still missing.
struct ChunkCache: Sendable {
    static let directoryName = ".transcripcion-parcial"

    let directory: URL
    let language: String

    init(folder: URL, language: String) {
        directory = folder.appending(path: Self.directoryName, directoryHint: .isDirectory)
        self.language = language
    }

    func segments(speaker: Speaker, chunk: AudioChunk) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: url(speaker, chunk)) else { return nil }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    /// Best effort: a chunk that cannot be cached is simply transcribed again on a retry.
    func store(_ segments: [TranscriptSegment], speaker: Speaker, chunk: AudioChunk) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(speaker, chunk), options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Language, start and duration are part of the name, so another language or chunk plan never reuses a stale chunk.
    private func url(_ speaker: Speaker, _ chunk: AudioChunk) -> URL {
        directory.appending(path: "\(language)-\(speaker.rawValue)-\(chunk.index)-\(Int(chunk.start))-\(Int(chunk.duration)).json")
    }
}
