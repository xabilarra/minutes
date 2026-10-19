import Foundation
import Testing
import MinutesCore

@Suite struct MetadataStoreTests {
    private func sampleMetadata() -> MeetingMetadata {
        var metadata = MeetingMetadata(
            appName: "Zoom",
            appBundleID: "us.zoom.xos",
            title: "Cliente X",
            windowTitle: "Zoom Meeting",
            trigger: "auto",
            startedAt: isoDate("2026-10-19T08:30:00Z"),
            hasVideo: true
        )
        metadata.endedAt = isoDate("2026-10-19T09:15:30Z")
        metadata.durationSeconds = 2730
        metadata.videoOffsetSeconds = 0.4
        metadata.transcription = TranscriptionStatus(
            state: .done, model: "whisper-large-v3", language: "es", completedAt: isoDate("2026-10-19T09:17:00Z")
        )
        return metadata
    }

    @Test func newMetadataUsesSchemaOneAndPendingTranscription() {
        let metadata = MeetingMetadata(
            appName: "Zoom", appBundleID: nil, title: nil, windowTitle: nil,
            trigger: "manual", startedAt: isoDate("2026-10-19T08:30:00Z"), hasVideo: false
        )
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.transcription == TranscriptionStatus(state: .pending))
        #expect(metadata.endedAt == nil)
        #expect(metadata.durationSeconds == nil)
        #expect(metadata.videoOffsetSeconds == nil)
    }

    @Test func writeThenReadRoundTripsEveryField() throws {
        try withTemporaryDirectory { folder in
            let metadata = sampleMetadata()
            try MetadataStore.write(metadata, to: folder)
            #expect(try MetadataStore.read(from: folder) == metadata)
        }
    }

    @Test func writesPrettyPrintedSortedJSONWithISO8601DatesToMetaJson() throws {
        try withTemporaryDirectory { folder in
            try MetadataStore.write(sampleMetadata(), to: folder)
            let json = try String(contentsOf: folder.appendingPathComponent("meta.json"), encoding: .utf8)
            #expect(json.contains("\n  \"appBundleID\" : \"us.zoom.xos\""))
            #expect(json.contains("\"startedAt\" : \"2026-10-19T08:30:00"))
            let keys = ["appBundleID", "appName", "durationSeconds", "endedAt", "hasVideo", "schemaVersion", "startedAt"]
            let offsets = keys.compactMap { json.range(of: "\"\($0)\"")?.lowerBound }
            #expect(offsets.count == keys.count)
            #expect(offsets == offsets.sorted())
        }
    }

    @Test func readAcceptsISO8601DatesWithAndWithoutFractionalSeconds() throws {
        try withTemporaryDirectory { folder in
            let json = """
            {"appName":"Zoom","hasVideo":false,"schemaVersion":1,"startedAt":"2026-10-19T08:30:00Z",
             "endedAt":"2026-10-19T09:00:00.250Z","transcription":{"state":"failed","error":"HTTP 500"},"trigger":"manual"}
            """
            try Data(json.utf8).write(to: folder.appendingPathComponent("meta.json"))
            let metadata = try MetadataStore.read(from: folder)
            #expect(metadata.startedAt == isoDate("2026-10-19T08:30:00Z"))
            #expect(metadata.endedAt == isoDate("2026-10-19T09:00:00Z").addingTimeInterval(0.25))
            #expect(metadata.transcription == TranscriptionStatus(state: .failed, error: "HTTP 500"))
        }
    }

    @Test func readThrowsWhenMetaJsonIsMissing() {
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinutesCoreTests-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: (any Error).self) { try MetadataStore.read(from: missingFolder) }
    }
}
