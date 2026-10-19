import Foundation

/// Locale-independent local date formatting (Gregorian, en_US_POSIX).
enum LocalDateFormat {
    /// A fresh formatter per call keeps this free of shared mutable state; callers format a handful of dates.
    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
