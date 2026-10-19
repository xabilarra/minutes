import Foundation
import Testing
import MinutesCore

@Suite struct MeetingDetectorTests {
    private let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
    private let teams = MeetingApp(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", isBrowser: false)
    private let chrome = MeetingApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", isBrowser: true)
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    /// Runs one detector update at `seconds` after the origin.
    private func tick(
        _ detector: inout MeetingDetector,
        _ ids: Set<String>,
        visible: Bool = false,
        at seconds: TimeInterval
    ) -> MeetingDetector.Event? {
        detector.update(activeInputBundleIDs: ids, browserMeetingVisible: visible, now: at(seconds))
    }

    /// A detector whose active meeting is Zoom, started at t = 3.
    private func detectorRecordingZoom() -> MeetingDetector {
        var detector = MeetingDetector()
        _ = tick(&detector, ["us.zoom.xos"], at: 0)
        _ = tick(&detector, ["us.zoom.xos"], at: 3)
        return detector
    }

    @Test func defaultConfigUsesThreeSecondStartAndFortyFiveSecondStop() {
        #expect(MeetingDetector.Config() == MeetingDetector.Config(startDelay: 3, stopDelay: 45))
    }

    @Test func startsOnceTheCandidateHasBeenPresentForTheStartDelay() {
        var detector = MeetingDetector()
        #expect(tick(&detector, ["us.zoom.xos"], at: 0) == nil)
        #expect(tick(&detector, ["us.zoom.xos.helper"], at: 2.9) == nil)
        #expect(detector.activeMeeting == nil)
        #expect(tick(&detector, ["us.zoom.xos"], at: 3) == .started(zoom))
        #expect(detector.activeMeeting == zoom)
        #expect(tick(&detector, ["us.zoom.xos"], at: 10) == nil)
    }

    @Test func startTimerRestartsWhenTheCandidateChanges() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["us.zoom.xos"], at: 0)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 2) == nil)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 4) == nil)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 5) == .started(teams))
    }

    @Test func startTimerRestartsWhenTheCandidateDisappears() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["us.zoom.xos"], at: 0)
        #expect(tick(&detector, [], at: 1) == nil)
        _ = tick(&detector, ["us.zoom.xos"], at: 2)
        #expect(tick(&detector, ["us.zoom.xos"], at: 4) == nil)
        #expect(tick(&detector, ["us.zoom.xos"], at: 5) == .started(zoom))
    }

    @Test func browserCountsOnlyWhileAMeetingWindowIsVisible() {
        var detector = MeetingDetector()
        #expect(tick(&detector, ["com.google.Chrome"], visible: false, at: 0) == nil)
        #expect(tick(&detector, ["com.google.Chrome"], visible: false, at: 10) == nil)
        #expect(detector.activeMeeting == nil)
        #expect(tick(&detector, ["com.google.Chrome"], visible: true, at: 11) == nil)
        #expect(tick(&detector, ["com.google.Chrome"], visible: true, at: 14) == .started(chrome))
    }

    @Test func nativeMeetingAppWinsOverAVisibleBrowserMeeting() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["com.google.Chrome", "us.zoom.xos"], visible: true, at: 0)
        #expect(tick(&detector, ["com.google.Chrome", "us.zoom.xos"], visible: true, at: 3) == .started(zoom))
    }

    @Test func stopsOnceTheMeetingAppReleasedTheMicForTheStopDelay() {
        var detector = detectorRecordingZoom()
        #expect(tick(&detector, [], at: 10) == nil)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 54.9) == nil)
        #expect(detector.activeMeeting == zoom)
        #expect(tick(&detector, [], at: 55) == .stopped(zoom))
        #expect(detector.activeMeeting == nil)
    }

    @Test func stopCountdownIsCancelledWhenTheMeetingAppReappears() {
        var detector = detectorRecordingZoom()
        _ = tick(&detector, [], at: 10)
        #expect(tick(&detector, ["us.zoom.xos.helper"], at: 30) == nil)
        _ = tick(&detector, [], at: 40)
        #expect(tick(&detector, [], at: 80) == nil)
        #expect(tick(&detector, [], at: 85) == .stopped(zoom))
    }

    @Test func browserMeetingIsNotStoppedByLosingWindowVisibility() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 0)
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 3)
        #expect(detector.activeMeeting == chrome)
        #expect(tick(&detector, ["com.google.Chrome"], visible: false, at: 100) == nil)
        #expect(tick(&detector, [], visible: false, at: 101) == nil)
        #expect(tick(&detector, [], visible: false, at: 146) == .stopped(chrome))
    }

    @Test func emitsAtMostOneEventPerUpdate() {
        var detector = detectorRecordingZoom()
        _ = tick(&detector, ["com.microsoft.teams2"], at: 10)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 55) == .stopped(zoom))
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 56) == nil)
        #expect(tick(&detector, ["com.microsoft.teams2"], at: 59) == .started(teams))
    }

    @Test func manualStopSuppressesAutoStartUntilTheMicIsReleased() {
        var detector = detectorRecordingZoom()
        detector.suppressUntilMicReleased()
        #expect(detector.activeMeeting == nil)
        #expect(tick(&detector, ["us.zoom.xos"], at: 10) == nil)
        #expect(tick(&detector, ["us.zoom.xos"], at: 100) == nil)
        #expect(detector.activeMeeting == nil)
        #expect(tick(&detector, [], at: 101) == nil)
        _ = tick(&detector, ["us.zoom.xos"], at: 200)
        #expect(tick(&detector, ["us.zoom.xos"], at: 203) == .started(zoom))
    }

    @Test func suppressionOfABrowserMeetingIsNotLiftedByHidingItsWindow() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 0)
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 3)
        detector.suppressUntilMicReleased()
        _ = tick(&detector, ["com.google.Chrome"], visible: false, at: 10)
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 20)
        #expect(tick(&detector, ["com.google.Chrome"], visible: true, at: 30) == nil)
        _ = tick(&detector, [], at: 40)
        _ = tick(&detector, ["com.google.Chrome"], visible: true, at: 50)
        #expect(tick(&detector, ["com.google.Chrome"], visible: true, at: 53) == .started(chrome))
    }

    @Test func exposesTheStopDeadlineWhileTheActiveAppHasReleasedTheMicrophone() {
        var detector = MeetingDetector()
        _ = tick(&detector, ["us.zoom.xos"], at: 0)
        #expect(tick(&detector, ["us.zoom.xos"], at: 3) == .started(zoom))
        #expect(detector.pendingStopDeadline == nil)

        _ = tick(&detector, [], at: 10)
        #expect(detector.pendingStopDeadline == at(55))
        _ = tick(&detector, [], at: 20)
        #expect(detector.pendingStopDeadline == at(55))

        _ = tick(&detector, ["us.zoom.xos"], at: 21)
        #expect(detector.pendingStopDeadline == nil)
    }
}

