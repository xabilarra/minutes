import AppKit
import Foundation
import Testing
@testable import Minutes

@MainActor @Suite struct RecordingIndicatorTests {
    private let indicator = RecordingIndicator()

    /// The crash of 2026-10-19: the hosting view resized the panel by itself whenever its text got
    /// wider, which sent AppKit into an endless Update Constraints loop. Only the indicator sizes it.
    @Test func theContentNeverResizesThePanelByItself() throws {
        defer { indicator.hide() }
        indicator.showRecording(appName: "Slack", since: Date())
        #expect(indicator.contentResizesPanel == false)
    }

    /// Crossing the hour widens the elapsed time ("59:59" → "1:00:00"), and the pill is not resized
    /// on every tick, so it is sized for an hour from the start.
    @Test func thePillIsAsWideBeforeAndAfterTheHour() throws {
        defer { indicator.hide() }
        indicator.showRecording(appName: "Slack", since: Date().addingTimeInterval(-59 * 60))
        let beforeTheHour = try laidOutPanelSize()
        indicator.showRecording(appName: "Slack", since: Date().addingTimeInterval(-61 * 60))
        let afterTheHour = try laidOutPanelSize()
        let fitting = try #require(indicator.contentFittingSize)

        #expect(beforeTheHour.width > 100)
        #expect(beforeTheHour == afterTheHour)
        #expect(fitting.width <= afterTheHour.width + 0.5)
    }

    /// Switching to the hang-up countdown resizes the pill once, to fit the new content.
    @Test func thePillFitsTheHangUpCountdown() throws {
        defer { indicator.hide() }
        indicator.showRecording(appName: "Slack", since: Date().addingTimeInterval(-3590))
        let recording = try laidOutPanelSize()
        indicator.updateStopCountdown(Date().addingTimeInterval(45))
        let countdown = try laidOutPanelSize()
        let fitting = try #require(indicator.contentFittingSize)

        #expect(recording.width > 100)
        #expect(countdown != recording)
        #expect(abs(countdown.width - fitting.width) <= 0.5)
    }

    private func laidOutPanelSize() throws -> NSSize {
        try #require(indicator.panelSize)
    }
}
