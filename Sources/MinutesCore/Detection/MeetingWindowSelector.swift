import Foundation

/// A snapshot of an on-screen window, as reported by the window server.
public struct WindowInfo: Equatable, Sendable {
    public let windowID: UInt32
    public let bundleID: String
    public let title: String
    /// Width in points.
    public let width: Double
    /// Height in points.
    public let height: Double

    public init(windowID: UInt32, bundleID: String, title: String, width: Double, height: Double) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
    }

    var area: Double { width * height }
}

/// Window-title heuristics: confirms browser meetings and picks the window to record.
public enum MeetingWindowSelector {
    /// Windows smaller than this (points) are toolbars, popovers or floating controls.
    static let minimumWidth: Double = 300
    static let minimumHeight: Double = 200

    private static let meetingTitlePrefixes = ["Meet - ", "Meet – "]
    private static let meetingTitleKeywords = [
        "google meet", "zoom meeting", "reunión de zoom", "microsoft teams",
        "whereby", "jitsi", "webex", "huddle", "discord",
    ]
    /// Extra hints accepted for native apps, whose windows are not shared with unrelated web pages.
    private static let nativeCallKeywords = ["meeting", "reunión", "call", "llamada", "huddle"]

    /// Case-insensitive meeting-like title: starts with "Meet - " or "Meet – ", contains "google meet", "zoom meeting", "reunión de zoom", "microsoft teams", "whereby", "jitsi", "webex", "huddle", "discord".
    public static func isMeetingTitle(_ title: String) -> Bool {
        meetingTitlePrefixes.contains { title.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
            || containsAny(title, meetingTitleKeywords)
    }

    /// Any window owned by a catalog browser (MeetingApp.matches) with a meeting-like title.
    public static func browserMeetingVisible(_ windows: [WindowInfo]) -> Bool {
        windows.contains { window in
            MeetingAppCatalog.app(forBundleID: window.bundleID)?.isBrowser == true && isMeetingTitle(window.title)
        }
    }

    /// Window to record for `app`: windows owned by app (matches), at least 300x200 points; prefer meeting-like titles (and for non-browsers also titles containing "meeting", "reunión", "call", "llamada", "huddle"); otherwise the largest area. nil if none.
    public static func select(for app: MeetingApp, among windows: [WindowInfo]) -> WindowInfo? {
        let eligible = windows.filter { window in
            app.ownsWindow(ofBundleID: window.bundleID)
                && window.width >= minimumWidth
                && window.height >= minimumHeight
        }
        let preferred = eligible.filter { window in
            isMeetingTitle(window.title) || (!app.isBrowser && containsAny(window.title, nativeCallKeywords))
        }
        return largest(preferred.isEmpty ? eligible : preferred)
    }

    /// Largest window by area; the first one wins ties.
    private static func largest(_ windows: [WindowInfo]) -> WindowInfo? {
        windows.reduce(nil) { best, window in
            guard let best, best.area >= window.area else { return window }
            return best
        }
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}
