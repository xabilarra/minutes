import Foundation

/// Minimal HTTP seam so the Groq client can be exercised without the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public enum GroqError: Error, Equatable, LocalizedError {
    case missingAPIKey
    /// message: server error text truncated to 500 chars; never contains the API key.
    case http(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "The Groq API key is missing."
        case let .http(status, message):
            message.isEmpty ? "Groq returned HTTP \(status)." : "Groq returned HTTP \(status): \(message)"
        case .invalidResponse:
            "Groq returned an unexpected response."
        }
    }
}

/// Client for Groq's OpenAI-compatible audio transcription endpoint.
public struct GroqClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let defaultModel = "whisper-large-v3"

    static let maximumErrorMessageLength = 500
    static let defaultRetryAfter: Double = 5
    /// Groq's hourly audio limit can ask for waits of several minutes.
    static let maximumRetryAfter: Double = 900
    /// Rate-limit waits allowed per file, on top of `maxAttempts` (a long meeting can hit the hourly limit often).
    static let maximumRateLimitWaits = 20
    static let initialBackoff: Double = 2
    static let maximumBackoff: Double = 60
    /// Idle timeout per request: uploads of a 10-minute chunk plus server processing stay well within it.
    static let requestTimeout: TimeInterval = 300

    private let apiKey: String
    private let transport: any HTTPTransport
    private let endpoint: URL
    private let maxAttempts: Int
    private let sleeper: @Sendable (Double) async throws -> Void

    /// - Parameters:
    ///   - apiKey: Groq API key; surrounding whitespace is ignored.
    ///   - maxAttempts: total attempts per file, including the first (values below 1 mean 1).
    ///   - sleeper: waits the given number of seconds between attempts (injected in tests).
    public init(
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = GroqClient.defaultEndpoint,
        maxAttempts: Int = 4,
        sleeper: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
        self.maxAttempts = maxAttempts
        self.sleeper = sleeper
    }

    /// POST multipart/form-data: file (filename = last path component, content type audio/mp4 for .m4a), model, language (if non-nil), prompt (if non-nil), response_format=verbose_json, temperature=0, timestamp_granularities[]=segment. Authorization: Bearer <key>.
    /// Retries: 429 → wait the longer of the Retry-After header and the "try again in 1m12s" of the message (default 5, max 900), up to 20 waits that do not count as attempts; 5xx and URLError → backoff 2, 4, 8 s; up to maxAttempts total attempts. Other 4xx → throw .http immediately (message from JSON {"error":{"message":...}} if present, else body text).
    ///
    /// Empty or whitespace API key → throws `.missingAPIKey` before any request. When attempts run out,
    /// the last HTTP failure is thrown as `.http` and the last network failure as its `URLError`.
    /// A cancelled task or `URLError.cancelled` is never retried.
    public func transcribe(
        fileURL: URL,
        model: String = GroqClient.defaultModel,
        language: String? = "es",
        prompt: String? = nil
    ) async throws -> [RawSegment] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GroqError.missingAPIKey }

        let request = Self.makeRequest(
            apiKey: key,
            endpoint: endpoint,
            fileData: try Data(contentsOf: fileURL),
            fileName: fileURL.lastPathComponent,
            model: model,
            language: language,
            prompt: prompt,
            boundary: "minutes-\(UUID().uuidString)"
        )
        let attempts = max(1, maxAttempts)
        var attempt = 0
        var rateLimitWaits = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let isLastAttempt = attempt >= attempts

            let reply: (Data, HTTPURLResponse)
            do {
                reply = try await transport.send(request)
            } catch let error as URLError where error.code != .cancelled && !isLastAttempt {
                try await sleeper(Self.backoffDelay(afterAttempt: attempt))
                continue
            }

            let (data, response) = reply
            switch response.statusCode {
            case 200..<300:
                return try Self.parseSegments(data)
            case 429 where rateLimitWaits < Self.maximumRateLimitWaits:
                rateLimitWaits += 1
                attempt -= 1
                try await sleeper(Self.retryAfterDelay(response, body: data))
            case 500...599 where !isLastAttempt:
                try await sleeper(Self.backoffDelay(afterAttempt: attempt))
            default:
                throw GroqError.http(status: response.statusCode, message: Self.errorMessage(from: data, redacting: key))
            }
        }
    }

    public static func makeRequest(
        apiKey: String,
        endpoint: URL,
        fileData: Data,
        fileName: String,
        model: String,
        language: String?,
        prompt: String?,
        boundary: String
    ) -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        form.addFile(name: "file", fileName: fileName, contentType: contentType(forFileName: fileName), data: fileData)
        form.addField(name: "model", value: model)
        if let language { form.addField(name: "language", value: language) }
        if let prompt { form.addField(name: "prompt", value: prompt) }
        form.addField(name: "response_format", value: "verbose_json")
        form.addField(name: "temperature", value: "0")
        form.addField(name: "timestamp_granularities[]", value: "segment")

        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.encoded()
        return request
    }

    /// Parses verbose_json "segments" (start, end, text, avg_logprob, no_speech_prob, compression_ratio). A response with only "text" and no "segments" → one segment [0, 0] with that text if non-empty.
    ///
    /// Anything that is not a JSON object with "segments" or "text" throws `.invalidResponse`.
    public static func parseSegments(_ data: Data) throws -> [RawSegment] {
        guard let response = try? JSONDecoder().decode(VerboseTranscription.self, from: data) else {
            throw GroqError.invalidResponse
        }
        if let segments = response.segments {
            return segments.map { segment in
                RawSegment(
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    avgLogprob: segment.avgLogprob,
                    noSpeechProb: segment.noSpeechProb,
                    compressionRatio: segment.compressionRatio
                )
            }
        }
        guard let text = response.text else { throw GroqError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [RawSegment(start: 0, end: 0, text: text)]
    }

    // MARK: - Retry policy

    /// 2, 4, 8 … seconds after the 1st, 2nd, 3rd … failed attempt, capped.
    static func backoffDelay(afterAttempt attempt: Int) -> Double {
        min(initialBackoff * pow(2, Double(max(0, attempt - 1))), maximumBackoff)
    }

    /// The longer of the Retry-After header (delta-seconds form) and the wait named in the error message
    /// ("Please try again in 1m12.5s"), clamped to [0, 900]; 5 when neither is present or parsable.
    static func retryAfterDelay(_ response: HTTPURLResponse, body: Data = Data()) -> Double {
        let header = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0.isFinite ? $0 : nil }
        let named = waitNamed(in: errorMessage(from: body, redacting: ""))
        guard let seconds = [header, named].compactMap(\.self).max() else { return defaultRetryAfter }
        return min(max(seconds, 0), maximumRetryAfter)
    }

    /// Seconds in "try again in 1h2m3.5s" or "345ms" (any of the h, m, s, ms parts), nil when absent.
    static func waitNamed(in message: String) -> Double? {
        guard let match = message.firstMatch(of: /try again in ((?:\d+(?:\.\d+)?(?:ms|[hms]))+)/) else { return nil }
        var total = 0.0
        for part in match.1.matches(of: /(\d+(?:\.\d+)?)(ms|[hms])/) {
            let value = Double(part.1) ?? 0
            switch part.2 {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "ms": total += value / 1000
            default: total += value
            }
        }
        return total
    }

    /// Server error text for `.http`: the JSON `error.message` when present, else the body, with the
    /// API key redacted (before truncation, so no fragment of it can survive) and truncated.
    static func errorMessage(from data: Data, redacting apiKey: String) -> String {
        let decoded = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
        var message = (decoded ?? String(decoding: data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            message = message.replacingOccurrences(of: apiKey, with: "[redacted]")
        }
        return String(message.prefix(maximumErrorMessageLength))
    }

    /// Upload content type by extension, limited to formats Groq accepts.
    static func contentType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "mp3", "mpga", "mpeg": "audio/mpeg"
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        case "ogg", "opus": "audio/ogg"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    // MARK: - Wire formats

    private struct VerboseTranscription: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            let avgLogprob: Double?
            let noSpeechProb: Double?
            let compressionRatio: Double?

            enum CodingKeys: String, CodingKey {
                case start, end, text
                case avgLogprob = "avg_logprob"
                case noSpeechProb = "no_speech_prob"
                case compressionRatio = "compression_ratio"
            }
        }

        let text: String?
        let segments: [Segment]?
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String?
        }

        let error: Detail?
    }
}

/// Builds a multipart/form-data body (RFC 7578).
struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(fileName))\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func encoded() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }

    /// Percent-encodes the characters that would break a quoted header parameter (WHATWG form encoding).
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
