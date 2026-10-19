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

    @Test func dropsSegmentsWhoseAudioIsSilentBecauseWhisperInventsThem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinutesPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "2026-10-19 10.30 Test (Google Meet)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 3 s of digital silence, then 3 s of tone: Whisper "hears" a "Gracias." in the silence.
        try writeTone(to: folder.appending(path: MeetingFile.micRaw.rawValue), seconds: 3, leadingSilence: 3)
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
                    (0.5, 2.0, "Gracias."), (3.5, 5.5, "hola soy yo"),
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

/// Captures every request body and answers with one short segment.
private actor RecordingGroqTransport: HTTPTransport {
    private(set) var bodies: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let json = #"{"text":"hola","segments":[{"start":0.0,"end":2.5,"text":" hola","avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1}]}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }
}
