import Foundation

/// Runs `body` with a fresh, uniquely named directory under the system temporary directory
/// (never inside the worktree) and removes it afterwards, even when `body` throws.
@discardableResult
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Async variant of `withTemporaryDirectory`.
@discardableResult
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinutesCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Parses an ISO 8601 timestamp such as "2026-10-19T08:30:00Z".
func isoDate(_ text: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: text) else {
        preconditionFailure("invalid test date \(text)")
    }
    return date
}

let madrid = TimeZone(identifier: "Europe/Madrid")!
let utc = TimeZone(identifier: "UTC")!
