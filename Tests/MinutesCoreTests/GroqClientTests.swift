import Foundation
import Testing
import MinutesCore

/// Scripted transport: replays canned replies in order and records every request it receives.
private actor FakeTransport: HTTPTransport {
    enum Reply {
        case response(status: Int, body: String, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case let .response(status, body, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        case let .failure(code):
            throw URLError(code)
        }
    }
}

/// Records requested waits instead of sleeping.
private actor SleepRecorder {
    private(set) var delays: [Double] = []
    func record(_ seconds: Double) { delays.append(seconds) }
}

@Suite struct GroqClientTests {
    private let verboseJSON = """
    {"task":"transcribe","language":"Spanish","duration":5.0,"text":" Hola. ¿Qué tal?",
     "segments":[
       {"id":0,"seek":0,"start":0.0,"end":1.5,"text":" Hola.","tokens":[1,2],"temperature":0.0,
        "avg_logprob":-0.21,"compression_ratio":0.8,"no_speech_prob":0.01},
       {"id":1,"seek":0,"start":1.5,"end":3,"text":" ¿Qué tal?"}
     ],
     "x_groq":{"id":"req_123"}}
    """

    private let expectedSegments = [
        RawSegment(start: 0, end: 1.5, text: " Hola.", avgLogprob: -0.21, noSpeechProb: 0.01, compressionRatio: 0.8),
        RawSegment(start: 1.5, end: 3, text: " ¿Qué tal?"),
    ]

    private func client(_ transport: FakeTransport, _ sleeps: SleepRecorder, apiKey: String = "gsk_test", maxAttempts: Int = 4) -> GroqClient {
        GroqClient(apiKey: apiKey, transport: transport, maxAttempts: maxAttempts, sleeper: { await sleeps.record($0) })
    }

    /// Runs `body` with a small fake audio file named `yo.m4a`.
    @discardableResult
    private func withAudioFile<T>(_ body: (URL) async throws -> T) async throws -> T {
        try await withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("yo.m4a")
            try Data("FAKE-AUDIO".utf8).write(to: file)
            return try await body(file)
        }
    }

    @Test func missingAPIKeyFailsBeforeAnyRequest() async throws {
        let transport = FakeTransport([.response(status: 200, body: verboseJSON)])
        let sleeps = SleepRecorder()
        for key in ["", "  \n"] {
            await #expect(throws: GroqError.missingAPIKey) {
                try await client(transport, sleeps, apiKey: key).transcribe(fileURL: URL(fileURLWithPath: "/nonexistent/yo.m4a"))
            }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func defaultsTargetGroqWhisperLargeV3() {
        #expect(GroqClient.defaultEndpoint.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(GroqClient.defaultModel == "whisper-large-v3")
    }

    @Test func requestIsAMultipartPostWithEveryFieldAndTheBearerHeader() throws {
        let request = GroqClient.makeRequest(
            apiKey: "gsk_test", endpoint: GroqClient.defaultEndpoint, fileData: Data("AUDIO".utf8),
            fileName: "yo-000.m4a", model: "whisper-large-v3", language: "es", prompt: "Reunión con Cliente X",
            boundary: "BOUNDARY"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url == GroqClient.defaultEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let expectedParts = [
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"yo-000.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nes\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nReunión con Cliente X\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"temperature\"\r\n\r\n0\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n",
        ]
        for part in expectedParts {
            #expect(body.contains(part), "\(part)")
        }
        #expect(body.hasPrefix("--BOUNDARY\r\n"))
        #expect(body.hasSuffix("--BOUNDARY--\r\n"))

        let minimal = GroqClient.makeRequest(
            apiKey: "gsk_test", endpoint: GroqClient.defaultEndpoint, fileData: Data("AUDIO".utf8),
            fileName: "ellos.m4a", model: "whisper-large-v3", language: nil, prompt: nil, boundary: "B"
        )
        let minimalBody = try #require(minimal.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!minimalBody.contains("name=\"language\""))
        #expect(!minimalBody.contains("name=\"prompt\""))
    }

    @Test func transcribeUploadsTheFileAndReturnsTheParsedSegments() async throws {
        let transport = FakeTransport([.response(status: 200, body: verboseJSON)])
        let segments = try await withAudioFile { file in
            try await client(transport, SleepRecorder(), apiKey: " gsk_test\n").transcribe(fileURL: file)
        }
        #expect(segments == expectedSegments)

        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("filename=\"yo.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nFAKE-AUDIO\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nes\r\n"))
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
    }

    @Test func rateLimitIsRetriedAfterTheRetryAfterHeader() async throws {
        let transport = FakeTransport([
            .response(status: 429, body: "{}", headers: ["Retry-After": "7"]),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        let segments = try await withAudioFile { file in
            try await client(transport, sleeps).transcribe(fileURL: file)
        }
        #expect(segments == expectedSegments)
        #expect(await sleeps.delays == [7])
        #expect(await transport.requests.count == 2)
    }

    @Test func rateLimitWaitDefaultsToFiveSecondsAndIsCappedAtFifteenMinutes() async throws {
        let transport = FakeTransport([
            .response(status: 429, body: "{}"),
            .response(status: 429, body: "{}", headers: ["retry-after": "1200"]),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        _ = try await withAudioFile { file in
            try await client(transport, sleeps).transcribe(fileURL: file)
        }
        #expect(await sleeps.delays == [5, 900])
    }

    /// Groq's audio-seconds-per-hour limit names the wait only in the message ("try again in 1m12s").
    @Test func rateLimitWaitsTheTimeGroqNamesInTheMessage() async throws {
        let message = #"{"error":{"message":"Rate limit reached for model `whisper-large-v3` on seconds of audio per hour (ASPH): Limit 7200, Used 6744, Requested 600. Please try again in 1m12.5s. Need more tokens?"}}"#
        let transport = FakeTransport([
            .response(status: 429, body: message, headers: ["Retry-After": "3"]),
            .response(status: 429, body: #"{"error":{"message":"Please try again in 8s."}}"#),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        _ = try await withAudioFile { file in
            try await client(transport, sleeps).transcribe(fileURL: file)
        }
        #expect(await sleeps.delays == [72.5, 8])
    }

    @Test func rateLimitReadsMillisecondsInTheMessageAsMilliseconds() async throws {
        let transport = FakeTransport([
            .response(status: 429, body: #"{"error":{"message":"Please try again in 345ms."}}"#),
            .response(status: 429, body: #"{"error":{"message":"Please try again in 1m2.5s."}}"#),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        _ = try await withAudioFile { file in
            try await client(transport, sleeps).transcribe(fileURL: file)
        }
        #expect(await sleeps.delays == [0.345, 62.5])
    }

    /// An hour-long meeting can hit the hourly limit many times: waiting it out must not use up the attempts.
    @Test func rateLimitWaitsDoNotUseUpTheAttempts() async throws {
        let transport = FakeTransport([
            .response(status: 429, body: "{}"),
            .response(status: 429, body: "{}"),
            .response(status: 429, body: "{}"),
            .response(status: 200, body: verboseJSON),
        ])
        let segments = try await withAudioFile { file in
            try await client(transport, SleepRecorder(), maxAttempts: 2).transcribe(fileURL: file)
        }
        #expect(segments == expectedSegments)
    }

    @Test func rateLimitGivesUpAfterTwentyWaits() async throws {
        let transport = FakeTransport(Array(repeating: .response(status: 429, body: "{}"), count: 30))
        await #expect(throws: GroqError.self) {
            try await withAudioFile { file in
                try await client(transport, SleepRecorder()).transcribe(fileURL: file)
            }
        }
        #expect(await transport.requests.count == 21)
    }

    @Test func serverErrorsAndNetworkFailuresAreRetriedWithExponentialBackoff() async throws {
        let transport = FakeTransport([
            .response(status: 500, body: "oops"),
            .failure(.timedOut),
            .response(status: 503, body: "busy"),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        let segments = try await withAudioFile { file in
            try await client(transport, sleeps).transcribe(fileURL: file)
        }
        #expect(segments == expectedSegments)
        #expect(await sleeps.delays == [2, 4, 8])
        #expect(await transport.requests.count == 4)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let failing = FakeTransport(Array(repeating: .response(status: 502, body: "bad gateway"), count: 5))
        let sleeps = SleepRecorder()
        try await withAudioFile { file in
            await #expect(throws: GroqError.http(status: 502, message: "bad gateway")) {
                try await client(failing, sleeps).transcribe(fileURL: file)
            }
        }
        #expect(await failing.requests.count == 4)
        #expect(await sleeps.delays == [2, 4, 8])

        let offline = FakeTransport([.failure(.notConnectedToInternet), .failure(.notConnectedToInternet)])
        try await withAudioFile { file in
            await #expect(throws: URLError(.notConnectedToInternet)) {
                try await client(offline, SleepRecorder(), maxAttempts: 2).transcribe(fileURL: file)
            }
        }
        #expect(await offline.requests.count == 2)
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let transport = FakeTransport([
            .response(status: 401, body: #"{"error":{"message":"Invalid API Key","type":"invalid_request_error"}}"#),
            .response(status: 200, body: verboseJSON),
        ])
        let sleeps = SleepRecorder()
        try await withAudioFile { file in
            await #expect(throws: GroqError.http(status: 401, message: "Invalid API Key")) {
                try await client(transport, sleeps).transcribe(fileURL: file)
            }
        }
        #expect(await transport.requests.count == 1)
        #expect(await sleeps.delays.isEmpty)
    }

    @Test func errorMessageFallsBackToTheBodyTruncatedWithoutTheAPIKey() async throws {
        let body = "Bad request for key gsk_secret_123: " + String(repeating: "x", count: 600)
        let transport = FakeTransport([.response(status: 400, body: body)])
        let error = try await withAudioFile { file in
            await #expect(throws: GroqError.self) {
                try await client(transport, SleepRecorder(), apiKey: "gsk_secret_123").transcribe(fileURL: file)
            }
        }
        guard case let .http(status, message)? = error else {
            Issue.record("expected an HTTP error, got \(String(describing: error))")
            return
        }
        #expect(status == 400)
        #expect(message.hasPrefix("Bad request for key "))
        #expect(!message.contains("gsk_secret_123"))
        #expect(message.count == 500)
    }

    @Test func parseSegmentsReadsVerboseJSONAndPlainTextResponses() throws {
        #expect(try GroqClient.parseSegments(Data(verboseJSON.utf8)) == expectedSegments)
        #expect(try GroqClient.parseSegments(Data(#"{"text":" Solo texto"}"#.utf8)) == [RawSegment(start: 0, end: 0, text: " Solo texto")])
        #expect(try GroqClient.parseSegments(Data(#"{"text":"  "}"#.utf8)).isEmpty)
        #expect(try GroqClient.parseSegments(Data(#"{"text":"x","segments":[]}"#.utf8)).isEmpty)
        #expect(throws: GroqError.invalidResponse) { try GroqClient.parseSegments(Data("<html>".utf8)) }
        #expect(throws: GroqError.invalidResponse) { try GroqClient.parseSegments(Data("{}".utf8)) }
    }

    /// Groq merges several Whisper segments into one and its "text" then loses every word from the
    /// first accented letter on ("según" → "seg"), while "tokens" still holds what Whisper said.
    private let truncatedJSON = """
    {"text":" hay seg que chat","segments":[
      {"start":143.8,"end":158.5,"text":" hay seg que chat","tokens":[50639,4842,36570,631,5081,50740],"avg_logprob":-0.13},
      {"start":158.5,"end":160,"text":" Vale.","tokens":[631,127]},
      {"start":160,"end":161,"text":" Sí."}
    ]}
    """

    @Test func parseSegmentsRebuildsTheTextFromTheTokensAndFallsBackToGroqText() throws {
        let tokenizer = try WhisperTokenizer(contentsOf: bundledVocabularyURL)
        #expect(try GroqClient.parseSegments(Data(truncatedJSON.utf8), tokenizer: tokenizer) == [
            RawSegment(start: 143.8, end: 158.5, text: " hay según que chat", avgLogprob: -0.13),
            RawSegment(start: 158.5, end: 160, text: " Vale."),
            RawSegment(start: 160, end: 161, text: " Sí."),
        ])
        // Without a tokenizer Groq's text is kept as it came.
        #expect(try GroqClient.parseSegments(Data(truncatedJSON.utf8)).first?.text == " hay seg que chat")
    }

    @Test func transcribeDecodesTheTokensWithTheClientsTokenizer() async throws {
        let tokenizer = try WhisperTokenizer(contentsOf: bundledVocabularyURL)
        let transport = FakeTransport([.response(status: 200, body: truncatedJSON)])
        let groq = GroqClient(apiKey: "gsk_test", transport: transport, tokenizer: tokenizer)
        let segments = try await withAudioFile { try await groq.transcribe(fileURL: $0) }
        #expect(segments.map(\.text) == [" hay según que chat", " Vale.", " Sí."])
    }
}
