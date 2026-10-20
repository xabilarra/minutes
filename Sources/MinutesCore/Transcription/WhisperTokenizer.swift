import Foundation

/// Turns Whisper token ids back into text with Whisper's own multilingual vocabulary.
///
/// Groq's verbose_json "text" can be wrong where its "tokens" are right: on segments it merges, the
/// text drops every word from its first accented letter on ("según" → "seg") and the punctuation.
public struct WhisperTokenizer: Sendable {
    public enum LoadError: Error, Equatable {
        /// 1-based line that is not "<base64 bytes> <rank>".
        case malformedLine(Int)
    }

    /// Ids from here on are special tokens (end of text, language, timestamps), never text.
    public static let firstSpecialToken = 50257

    private let bytesByToken: [Int: Data]

    /// Reads a tiktoken vocabulary: one "<base64 bytes> <rank>" per line, blank lines ignored.
    public init(tiktoken contents: String) throws {
        var bytesByToken: [Int: Data] = [:]
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: " ")
            // Whisper's vocabulary ends with "= 50256", an empty token Foundation does not read as base64.
            let encoded = fields.first.map(String.init) ?? ""
            guard fields.count == 2, let bytes = encoded == "=" ? Data() : Data(base64Encoded: encoded),
                  let rank = Int(fields[1]) else {
                throw LoadError.malformedLine(index + 1)
            }
            bytesByToken[rank] = bytes
        }
        self.bytesByToken = bytesByToken
    }

    public init(contentsOf url: URL) throws {
        try self.init(tiktoken: String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    /// The text of `tokens`, skipping special ones; nil when there is no text token, an id is not in
    /// the vocabulary, or the bytes are not valid UTF-8 (a character split across segments).
    public func text(of tokens: [Int]) -> String? {
        var bytes = Data()
        for token in tokens where token < Self.firstSpecialToken {
            guard let piece = bytesByToken[token] else { return nil }
            bytes.append(piece)
        }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
