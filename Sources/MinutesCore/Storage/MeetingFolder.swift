import Foundation

/// Naming and placement of per-meeting folders under the recordings root.
public enum MeetingFolder {
    /// Longest sanitized text kept in a folder name.
    static let maximumSanitizedLength = 80

    /// Characters that are path separators in Finder ("/", ":") or in shells ("\\").
    private static let forbiddenScalars: Set<Unicode.Scalar> = ["/", ":", "\\"]

    /// "yyyy-MM-dd HH.mm <title> (<appName>)" or "yyyy-MM-dd HH.mm <appName>" when title is nil/empty after sanitizing. Gregorian calendar, en_US_POSIX, given timeZone.
    public static func folderName(start: Date, title: String?, appName: String, timeZone: TimeZone = .current) -> String {
        let stamp = LocalDateFormat.string(from: start, format: "yyyy-MM-dd HH.mm", timeZone: timeZone)
        let app = sanitize(appName)
        let cleanTitle = title.map(sanitize) ?? ""
        if cleanTitle.isEmpty {
            return app.isEmpty ? stamp : "\(stamp) \(app)"
        }
        return app.isEmpty ? "\(stamp) \(cleanTitle)" : "\(stamp) \(cleanTitle) (\(app))"
    }

    /// Removes "/", ":", "\\" and control characters, collapses whitespace, trims, max 80 characters (no trailing space).
    ///
    /// Whitespace control characters (newlines, tabs) become spaces so the words they separate stay apart.
    public static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if !forbiddenScalars.contains(scalar), scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars).split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(maximumSanitizedLength)).trimmingCharacters(in: .whitespaces)
    }

    /// root/name, or root/"name (2)", "name (3)"... when it already exists.
    public static func uniqueURL(in root: URL, name: String, fileManager: FileManager = .default) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) (\(counter))", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    /// Default root: ~/Reuniones
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Reuniones", isDirectory: true)
    }
}
