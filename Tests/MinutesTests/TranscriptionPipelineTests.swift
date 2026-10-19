import AVFoundation
import Foundation
import MinutesCapture
import MinutesCore
import Testing
@testable import Minutes

@Suite struct TranscriptionPipelineTests {
    @Test func keepsBothRawTracksUntilTheTranscriptIsWrittenSoARetryKeepsEveryLine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Zoom)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3)
        try writeTone(to: folder.appending(path: MeetingFile.systemRaw.rawValue), seconds: 3)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Zoom", appBundleID: "us.zoom.xos", title: "Test", windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let failSystemExport = Flag(true)
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            makeClient: { GroqClient(apiKey: $0, transport: FakeGroqTransport(), sleeper: { _ in }) },
            exportFinalAudio: { source, destination in
                if destination.lastPathComponent == MeetingFile.systemAudio.rawValue, failSystemExport.value {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try AudioFileTools.exportM4A(from: source, to: destination)
            },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == true)
        #expect(exists(folder, .micRaw))
        #expect(exists(folder, .systemRaw))
        #expect(try MetadataStore.read(from: folder).transcription.state == .failed)

        failSystemExport.value = false
        await pipeline.retryFailed()
        #expect(await results.next() == false)
        let markdown = try String(
            contentsOf: folder.appending(path: MeetingFile.transcriptMarkdown.rawValue), encoding: .utf8)
        #expect(markdown.contains("Yo: hola soy yo"))
        #expect(markdown.contains("Ellos: hola somos ellos"))
        #expect(try MetadataStore.read(from: folder).transcription.state == .done)
        #expect(!exists(folder, .micRaw))
        #expect(!exists(folder, .systemRaw))
        #expect(exists(folder, .micAudio))
        #expect(exists(folder, .systemAudio))
    }

    /// A retry after a failure (Groq's hourly limit) must not pay again for the audio already transcribed.
    @Test func aRetryReusesTheChunksAlreadyTranscribed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Zoom)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3)
        try writeTone(to: folder.appending(path: MeetingFile.systemRaw.rawValue), seconds: 3)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Zoom", appBundleID: "us.zoom.xos", title: "Test", windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let transport = FailingThemOnceTransport()
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            makeClient: { GroqClient(apiKey: $0, transport: transport, sleeper: { _ in }) },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == true)
        await pipeline.retryFailed()
        #expect(await results.next() == false)

        #expect(await transport.requests(for: .me) == 1)
        #expect(await transport.requests(for: .them) == 2)
        let markdown = try String(
            contentsOf: folder.appending(path: MeetingFile.transcriptMarkdown.rawValue), encoding: .utf8)
        #expect(markdown.contains("Yo: hola soy yo"))
        #expect(markdown.contains("Ellos: hola somos ellos"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(leftovers) == Set([
            MeetingFile.micAudio, .systemAudio, .transcriptMarkdown, .transcriptJSON, .metadata,
        ].map(\.rawValue)))
    }

    /// Chunks cached in one language are not reused after the user switches language for a retry.
    @Test func aRetryInAnotherLanguageTranscribesAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Zoom)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3)
        try writeTone(to: folder.appending(path: MeetingFile.systemRaw.rawValue), seconds: 3)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Zoom", appBundleID: "us.zoom.xos", title: "Test", windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let transport = FailingThemOnceTransport()
        let language = LanguageBox("es")
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            languageProvider: { language.value },
            makeClient: { GroqClient(apiKey: $0, transport: transport, sleeper: { _ in }) },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == true)
        language.value = "en"
        await pipeline.retryFailed()
        #expect(await results.next() == false)

        #expect(await transport.requests(for: .me) == 2)
    }

    @Test func dropsSegmentsWhoseAudioIsSilentBecauseWhisperInventsThem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Google Meet)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 1 s of digital silence (too short to be cut), then 3 s of tone: Whisper "hears" a "Gracias." in the silence.
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3, leadingSilence: 1)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Google Meet", appBundleID: "com.google.Chrome", title: nil, windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            makeClient: {
                GroqClient(apiKey: $0, transport: FixedGroqTransport(segments: [
                    (0.1, 0.9, "Gracias."), (1.5, 3.5, "hola soy yo"),
                ]), sleeper: { _ in })
            },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == false)
        let markdown = try String(
            contentsOf: folder.appending(path: MeetingFile.transcriptMarkdown.rawValue), encoding: .utf8)
        #expect(markdown.contains("Yo: hola soy yo"))
        #expect(!markdown.contains("Gracias"))
    }

    /// Only the speech is uploaded (Groq bills and rate-limits seconds of audio), and Whisper's times
    /// in the uploaded audio are mapped back to the recording.
    @Test func uploadsOnlyTheSpeechAndKeepsTheRecordingTimes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Zoom)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The other side talks for 20 s, then the user speaks for 3 s.
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3, leadingSilence: 20)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Zoom", appBundleID: "us.zoom.xos", title: nil, windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let transport = RecordingGroqTransport()
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            makeClient: { GroqClient(apiKey: $0, transport: transport, sleeper: { _ in }) },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == false)
        #expect(await transport.bodies.count == 1)
        // 1 s of context before the speech and after it, through the end of the track: 4 s of 23 s.
        let uploaded = try #require(await transport.uploadedDurations.first)
        #expect(abs(uploaded - 4) < 0.2)
        let markdown = try String(
            contentsOf: folder.appending(path: MeetingFile.transcriptMarkdown.rawValue), encoding: .utf8)
        // Whisper's "hola" at 0 s of the upload is at 19 s of the recording.
        #expect(markdown.contains("[00:00:19] Yo: hola"))
    }

    @Test(arguments: [("en", true), (nil, false)] as [(String?, Bool)])
    func sendsTheConfiguredLanguageOrLetsWhisperDetectIt(language: String?, sendsLanguage: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Zoom)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3)
        try MetadataStore.write(
            MeetingMetadata(
                appName: "Zoom", appBundleID: "us.zoom.xos", title: nil, windowTitle: nil,
                trigger: "auto", startedAt: Date(), hasVideo: false),
            to: folder)

        let transport = RecordingGroqTransport()
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = TranscriptionPipeline(
            root: root,
            apiKeyProvider: { "gsk_test" },
            languageProvider: { language },
            makeClient: { GroqClient(apiKey: $0, transport: transport, sleeper: { _ in }) },
            onStatus: { _ in },
            onFinished: { _, failure in continuation.yield(failure != nil) })
        var results = finished.makeAsyncIterator()

        await pipeline.enqueue(folder)
        #expect(await results.next() == false)
        let body = try #require(await transport.bodies.first)
        #expect(body.contains("name=\"language\"") == sendsLanguage)
        if let language {
            #expect(body.contains("name=\"language\"\r\n\r\n\(language)\r\n"))
        }
        #expect(try MetadataStore.read(from: folder).transcription.language == (language ?? "auto"))
    }

    private func exists(_ folder: URL, _ file: MeetingFile) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: file.rawValue).path)
    }

    /// 16 kHz mono Int16 CAF with a 440 Hz tone after optional silence, like the recorders write.
    private func writeTone(to url: URL, seconds: Double, leadingSilence: Double = 0) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let silentFrames = Int(leadingSilence * 16_000)
        let frames = AVAudioFrameCount(Double(silentFrames) + seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = index < silentFrames ? 0 : 0.3 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        try file.write(from: buffer)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Answers like Groq's verbose_json, with text depending on which track the chunk came from.
private struct FakeGroqTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let text = body.contains("\(Speaker.me.rawValue)-0.m4a") ? "hola soy yo" : "hola somos ellos"
        let json = """
            {"text":"\(text)","segments":[{"start":0.0,"end":2.5,"text":" \(text)",\
            "avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1}]}
            """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }
}

/// Answers every chunk with the same verbose_json segments.
private struct FixedGroqTransport: HTTPTransport {
    let segments: [(start: Double, end: Double, text: String)]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let items = segments.map {
            #"{"start":\#($0.start),"end":\#($0.end),"text":" \#($0.text)","avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1}"#
        }
        let json = #"{"text":"","segments":[\#(items.joined(separator: ","))]}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }
}

private final class LanguageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) { stored = value }

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Answers like `FakeGroqTransport`, but rejects the first "Ellos" chunk; counts requests per track.
private actor FailingThemOnceTransport: HTTPTransport {
    private var counts: [Speaker: Int] = [:]

    func requests(for speaker: Speaker) -> Int { counts[speaker] ?? 0 }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let speaker: Speaker = body.contains("\(Speaker.me.rawValue)-0.m4a") ? .me : .them
        counts[speaker, default: 0] += 1
        if speaker == .them, counts[speaker] == 1 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":{"message":"rejected"}}"#.utf8), response)
        }
        return try await FakeGroqTransport().send(request)
    }
}

/// Captures every request body and the duration of its audio, and answers with one short segment.
private actor RecordingGroqTransport: HTTPTransport {
    private(set) var bodies: [String] = []
    private(set) var uploadedDurations: [Double] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = request.httpBody ?? Data()
        bodies.append(String(decoding: data, as: UTF8.self))
        uploadedDurations.append(Self.audioDuration(inMultipart: data))
        let json = #"{"text":"hola","segments":[{"start":0.0,"end":2.5,"text":" hola","avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1}]}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }

    /// Duration of the m4a in a multipart body, read by writing the bytes after the file part's headers to disk.
    private static func audioDuration(inMultipart body: Data) -> Double {
        let headerEnd = Data("\r\n\r\n".utf8)
        guard let fileHeader = body.range(of: Data("filename=".utf8)),
              let start = body.range(of: headerEnd, in: fileHeader.upperBound..<body.endIndex)?.upperBound,
              let end = body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)?.lowerBound
        else { return -1 }
        let url = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? body[start..<end].write(to: url)) != nil else { return -1 }
        return (try? AudioFileTools.duration(of: url)) ?? -1
    }
}
