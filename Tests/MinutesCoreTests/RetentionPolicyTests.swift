import Foundation
import Testing
import MinutesCore

@Suite struct RetentionPolicyTests {
    private let now = isoDate("2026-10-19T12:00:00Z")
    private let day: TimeInterval = 86_400

    /// Creates `root/name` with the given files; writes meta.json when `startedAt` is given.
    @discardableResult
    private func makeMeeting(
        _ root: URL, _ name: String, startedAt: Date?, files: [String] = ["video.mp4", "yo.m4a"]
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: folder.appendingPathComponent(file))
        }
        if let startedAt {
            let metadata = MeetingMetadata(
                appName: "Zoom", appBundleID: nil, title: nil, windowTitle: nil,
                trigger: "auto", startedAt: startedAt, hasVideo: files.contains("video.mp4")
            )
            try MetadataStore.write(metadata, to: folder)
        }
        return folder
    }

    @Test func listsOnlyVideosOfMeetingsOlderThanTheRetention() throws {
        try withTemporaryDirectory { root in
            let old = try makeMeeting(root, "old", startedAt: now.addingTimeInterval(-40 * day))
            try makeMeeting(root, "recent", startedAt: now.addingTimeInterval(-10 * day))
            try makeMeeting(root, "exactly-30-days", startedAt: now.addingTimeInterval(-30 * day))
            try makeMeeting(root, "old-without-video", startedAt: now.addingTimeInterval(-40 * day), files: ["yo.m4a"])
            try makeMeeting(root, "no-meta", startedAt: nil)
            let corrupt = try makeMeeting(root, "corrupt-meta", startedAt: nil)
            try Data("{".utf8).write(to: corrupt.appendingPathComponent("meta.json"))
            try Data("x".utf8).write(to: root.appendingPathComponent("video.mp4"))

            let videos = try RetentionPolicy(videoRetentionDays: 30).videosToDelete(root: root, now: now)

            #expect(videos.map(\.standardizedFileURL) == [old.appendingPathComponent("video.mp4").standardizedFileURL])
        }
    }

    @Test func keepsEveryVideoWhenRetentionIsOff() throws {
        try withTemporaryDirectory { root in
            try makeMeeting(root, "ancient", startedAt: now.addingTimeInterval(-3_650 * day))
            #expect(try RetentionPolicy(videoRetentionDays: nil).videosToDelete(root: root, now: now).isEmpty)
        }
    }

    @Test func rootMayBeASymbolicLinkToTheRecordingsFolder() throws {
        try withTemporaryDirectory { directory in
            let realRoot = directory.appendingPathComponent("external", isDirectory: true)
            let old = try makeMeeting(realRoot, "old", startedAt: now.addingTimeInterval(-40 * day))
            let linkedRoot = directory.appendingPathComponent("Reuniones", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

            let videos = try RetentionPolicy(videoRetentionDays: 30).videosToDelete(root: linkedRoot, now: now)

            #expect(videos.map { $0.resolvingSymlinksInPath() }
                == [old.appendingPathComponent("video.mp4").resolvingSymlinksInPath()])
        }
    }

    @Test func missingRootHasNothingToDelete() throws {
        try withTemporaryDirectory { root in
            let missing = root.appendingPathComponent("Reuniones", isDirectory: true)
            let videos = try RetentionPolicy(videoRetentionDays: 30).videosToDelete(root: missing, now: now)
            #expect(videos.isEmpty)
        }
    }
}
