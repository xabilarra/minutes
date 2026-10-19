import Foundation

/// Shared JSON conventions for every file Minutes writes: pretty printed, sorted keys,
/// ISO 8601 UTC dates with milliseconds. Reading also accepts dates without fractional seconds
/// (the parse strategy treats the fraction as optional), so hand-edited files stay readable.
enum MinutesJSON {
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            do {
                return try Date(text, strategy: dateStyle)
            } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(text)")
            }
        }
        return decoder
    }
}
