import AppKit
import Foundation
import MinutesCore
import Testing
@testable import Minutes

@MainActor @Suite struct LastMeetingActionsTests {
    private let folder: URL
    private let coordinator = RecordingCoordinator()
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("minutes-tests-\(UUID().uuidString)"))

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "MinutesActionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        coordinator.pasteboard = pasteboard
    }

    @Test func copyTranscriptPutsTheWholeMarkdownOnThePasteboard() throws {
        defer { cleanUp() }
        let markdown = "# Google Meet — 2026-10-19 10:30\n\n## Transcripción\n\n[00:00:03] Ellos: Hola.\n"
        try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        #expect(coordinator.copyTranscript(of: folder))
        #expect(pasteboard.string(forType: .string) == markdown)
    }

    @Test func copyTranscriptPathPutsTheTranscriptFilePathOnThePasteboard() throws {
        defer { cleanUp() }
        try "x".write(to: transcriptURL, atomically: true, encoding: .utf8)

        #expect(coordinator.copyTranscriptPath(of: folder))
        #expect(pasteboard.string(forType: .string) == transcriptURL.path)
        #expect(pasteboard.string(forType: .fileURL) == transcriptURL.absoluteString)
    }

    @Test func copyingWithoutATranscriptLeavesThePasteboardAndExplainsWhy() {
        defer { cleanUp() }
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)

        #expect(!coordinator.copyTranscript(of: folder))
        #expect(!coordinator.copyTranscriptPath(of: folder))
        #expect(pasteboard.string(forType: .string) == "previous")
        #expect(coordinator.lastProblem != nil)
    }

    private var transcriptURL: URL { folder.appending(path: MeetingFile.transcriptMarkdown.rawValue) }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        pasteboard.releaseGlobally()
    }
}
