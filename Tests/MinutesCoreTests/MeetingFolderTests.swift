import Foundation
import Testing
import MinutesCore

@Suite struct MeetingFolderTests {
    private let start = isoDate("2026-10-19T08:30:59Z")

    @Test func meetingFileNamesFollowTheAcceptedLayout() {
        #expect(MeetingFile.video.rawValue == "video.mp4")
        #expect(MeetingFile.micAudio.rawValue == "yo.m4a")
        #expect(MeetingFile.systemAudio.rawValue == "ellos.m4a")
        #expect(MeetingFile.micRaw.rawValue == "yo.caf")
        #expect(MeetingFile.systemRaw.rawValue == "ellos.caf")
        #expect(MeetingFile.transcriptMarkdown.rawValue == "transcripcion.md")
        #expect(MeetingFile.transcriptJSON.rawValue == "transcripcion.json")
        #expect(MeetingFile.metadata.rawValue == "meta.json")
        #expect(MeetingFile.allCases.count == 8)
    }

    @Test func folderNameCombinesLocalStartTitleAndApp() {
        #expect(MeetingFolder.folderName(start: start, title: "Cliente X", appName: "Zoom", timeZone: madrid)
            == "2026-10-19 10.30 Cliente X (Zoom)")
        #expect(MeetingFolder.folderName(start: start, title: "Cliente X", appName: "Zoom", timeZone: utc)
            == "2026-10-19 08.30 Cliente X (Zoom)")
    }

    @Test func folderNameFallsBackToAppNameWhenTitleIsMissing() {
        for title in [nil, "", "  /: "] as [String?] {
            #expect(MeetingFolder.folderName(start: start, title: title, appName: "Zoom", timeZone: madrid)
                == "2026-10-19 10.30 Zoom")
        }
    }

    @Test func sanitizeRemovesPathAndControlCharactersAndCollapsesWhitespace() {
        #expect(MeetingFolder.sanitize("Cliente/X: plan\\Q4\u{07}") == "ClienteX planQ4")
        #expect(MeetingFolder.sanitize("  Plan \n\t semanal  ") == "Plan semanal")
        #expect(MeetingFolder.sanitize("A / B") == "A B")
    }

    @Test func sanitizeKeepsAtMostEightyCharactersWithoutTrailingSpace() {
        #expect(MeetingFolder.sanitize(String(repeating: "a", count: 100)) == String(repeating: "a", count: 80))
        let cutAtSpace = String(repeating: "b", count: 79) + " cdef"
        #expect(MeetingFolder.sanitize(cutAtSpace) == String(repeating: "b", count: 79))
    }

    @Test func uniqueURLAddsACounterWhenTheFolderExists() throws {
        try withTemporaryDirectory { root in
            let name = "2026-10-19 10.30 Zoom"
            let first = MeetingFolder.uniqueURL(in: root, name: name)
            #expect(first.lastPathComponent == name)
            #expect(first.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)

            let second = MeetingFolder.uniqueURL(in: root, name: name)
            #expect(second.lastPathComponent == "\(name) (2)")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

            #expect(MeetingFolder.uniqueURL(in: root, name: name).lastPathComponent == "\(name) (3)")
        }
    }

    @Test func defaultRootIsReunionesInTheHomeFolder() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Reuniones")
        #expect(MeetingFolder.defaultRoot.standardizedFileURL.path == expected.standardizedFileURL.path)
    }
}
