import Foundation

/// Reads and writes `meta.json` inside a meeting folder.
public enum MetadataStore {
    /// folder/meta.json, pretty printed, sorted keys, ISO 8601 dates, atomic write.
    ///
    /// The folder must already exist: a missing folder is reported instead of silently recreated.
    public static func write(_ metadata: MeetingMetadata, to folder: URL) throws {
        let data = try MinutesJSON.makeEncoder().encode(metadata)
        try data.write(to: fileURL(in: folder), options: .atomic)
    }

    public static func read(from folder: URL) throws -> MeetingMetadata {
        let data = try Data(contentsOf: fileURL(in: folder))
        return try MinutesJSON.makeDecoder().decode(MeetingMetadata.self, from: data)
    }

    private static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(MeetingFile.metadata.rawValue, isDirectory: false)
    }
}
