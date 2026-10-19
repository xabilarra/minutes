import Foundation

/// Debounced meeting start/stop detection from periodic snapshots of microphone users.
///
/// The caller polls the bundle IDs of processes with active audio input (and whether a browser
/// shows a meeting window) and feeds them to `update`. The detector is a pure state machine:
/// time only advances through the `now` argument, which makes it deterministic to test.
public struct MeetingDetector: Sendable {
    public struct Config: Sendable, Equatable {
        /// Seconds a candidate must hold the microphone before a meeting starts.
        public var startDelay: TimeInterval
        /// Seconds the active meeting app must have released the microphone before it stops.
        public var stopDelay: TimeInterval

        public init(startDelay: TimeInterval = 3, stopDelay: TimeInterval = 45) {
            self.startDelay = startDelay
            self.stopDelay = stopDelay
        }
    }

    public enum Event: Equatable, Sendable {
        case started(MeetingApp)
        case stopped(MeetingApp)
    }

    public private(set) var activeMeeting: MeetingApp?

    /// When the active meeting will stop unless its app takes the microphone again; nil while the
    /// app holds it or no meeting is active. Lets the UI show a countdown right after hanging up.
    public var pendingStopDeadline: Date? {
        guard activeMeeting != nil, let releasedSince else { return nil }
        return releasedSince.addingTimeInterval(config.stopDelay)
    }

    private let config: Config
    /// Candidate waiting for `startDelay`, and when it was first seen without interruption.
    private var pendingStart: (app: MeetingApp, since: Date)?
    /// When the active meeting app was last seen releasing the microphone.
    private var releasedSince: Date?
    private var isSuppressed = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds one snapshot and returns at most one event.
    ///
    /// - Parameters:
    ///   - activeInputBundleIDs: bundle IDs of processes currently capturing audio input.
    ///   - browserMeetingVisible: whether a browser window currently shows a meeting.
    ///   - now: the snapshot time.
    public mutating func update(activeInputBundleIDs: Set<String>, browserMeetingVisible: Bool, now: Date) -> Event? {
        if isSuppressed {
            // Lifted only once no meeting app (browsers included, whatever their windows show)
            // holds the microphone, so hiding a meeting tab does not re-arm auto-start.
            guard MeetingAppCatalog.candidates(in: activeInputBundleIDs).isEmpty else {
                return nil
            }
            isSuppressed = false
        }

        if let active = activeMeeting {
            return checkStop(of: active, activeInputBundleIDs: activeInputBundleIDs, now: now)
        }

        let candidate = MeetingAppCatalog.candidates(in: activeInputBundleIDs)
            .first { !$0.isBrowser || browserMeetingVisible }
        return checkStart(of: candidate, now: now)
    }

    /// User stopped a recording manually: no auto-start until no candidate remains (the meeting app released the mic), then normal behaviour resumes. Also clears activeMeeting.
    ///
    /// "No candidate" is evaluated on microphone use alone: a browser still holding the
    /// microphone keeps the suppression even while its meeting window is hidden.
    public mutating func suppressUntilMicReleased() {
        isSuppressed = true
        activeMeeting = nil
        pendingStart = nil
        releasedSince = nil
    }

    private mutating func checkStart(of candidate: MeetingApp?, now: Date) -> Event? {
        guard let candidate else {
            pendingStart = nil
            return nil
        }
        if pendingStart?.app != candidate {
            pendingStart = (candidate, now)
        }
        guard let pending = pendingStart, now.timeIntervalSince(pending.since) >= config.startDelay else {
            return nil
        }
        pendingStart = nil
        releasedSince = nil
        activeMeeting = candidate
        return .started(candidate)
    }

    private mutating func checkStop(of active: MeetingApp, activeInputBundleIDs: Set<String>, now: Date) -> Event? {
        // Browser visibility is deliberately ignored here: only releasing the microphone ends a meeting.
        if activeInputBundleIDs.contains(where: active.matches(bundleID:)) {
            releasedSince = nil
            return nil
        }
        let since = releasedSince ?? now
        releasedSince = since
        guard now.timeIntervalSince(since) >= config.stopDelay else {
            return nil
        }
        activeMeeting = nil
        releasedSince = nil
        pendingStart = nil
        return .stopped(active)
    }
}
