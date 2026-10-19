import AppKit
import Foundation
import Testing
@testable import Minutes

@MainActor @Suite struct RecordingIndicatorTests {
    private let indicator = RecordingIndicator()

    /// Crossing the hour widens the elapsed time ("59:59" → "1:00:00"); the pill must keep its size
    /// (the panel is only resized by the indicator itself) and still fit its content.
    @Test func pillKeepsItsSizeWhenTheElapsedTimeCrossesTheHour() throws {
        defer { indicator.hide() }
        indicator.showRecording(appName: "Slack", since: Date().addingTimeInterval(-3598.5))
        let initial = try #require(indicator.panelSize)

        pumpRunLoop(seconds: 2.5)

        #expect(indicator.panelSize == initial)
        let fitting = try #require(indicator.contentFittingSize)
        #expect(fitting.width <= initial.width + 0.5)
    }

    /// The hang-up countdown that ran when the app crashed on 2026-10-19: switching to it and
    /// ticking must resize the pill once, to fit the new content, and never again per tick.
    @Test func pillResizesOnceToFitTheHangUpCountdown() throws {
        defer { indicator.hide() }
        indicator.showRecording(appName: "Slack", since: Date().addingTimeInterval(-3590))
        indicator.updateStopCountdown(Date().addingTimeInterval(45))
        let countdown = try #require(indicator.panelSize)
        let fitting = try #require(indicator.contentFittingSize)
        #expect(abs(countdown.width - fitting.width) <= 0.5)

        pumpRunLoop(seconds: 2.5)

        #expect(indicator.panelSize == countdown)
    }

    private func pumpRunLoop(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
