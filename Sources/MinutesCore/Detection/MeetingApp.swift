import Foundation

/// An application whose microphone use can indicate a video call.
///
/// Native meeting apps (Zoom, Teams, …) are trusted on microphone use alone; browsers
/// (`isBrowser == true`) also need a meeting-like window title before they count,
/// because a browser holding the mic is not necessarily in a call.
public struct MeetingApp: Equatable, Hashable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let isBrowser: Bool

    public init(bundleID: String, displayName: String, isBrowser: Bool) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.isBrowser = isBrowser
    }

    /// True when `other` equals bundleID or is a helper of it (hasPrefix(bundleID + ".")), case-insensitive.
    ///
    /// The "." boundary keeps `com.microsoft.teams` from matching `com.microsoft.teams2`.
    public func matches(bundleID other: String) -> Bool {
        Self.bundleID(other, isOrHelperOf: bundleID)
    }

    /// True when a window owned by `windowOwner` belongs to this app.
    ///
    /// Same as `matches(bundleID:)`, except for Safari's media process (`com.apple.WebKit.GPU`):
    /// it holds the microphone during a Safari call but owns no windows, so Safari's windows
    /// are attributed to it.
    public func ownsWindow(ofBundleID windowOwner: String) -> Bool {
        if matches(bundleID: windowOwner) {
            return true
        }
        guard let alias = MeetingAppCatalog.windowOwnerAliases[bundleID.lowercased()] else {
            return false
        }
        return Self.bundleID(windowOwner, isOrHelperOf: alias)
    }

    /// Case-insensitive: `candidate` equals `base` or starts with `base + "."`.
    private static func bundleID(_ candidate: String, isOrHelperOf base: String) -> Bool {
        let candidate = candidate.lowercased()
        let base = base.lowercased()
        return candidate == base || candidate.hasPrefix(base + ".")
    }
}

/// Known meeting apps and browsers, matched against the bundle IDs of processes using the microphone.
public enum MeetingAppCatalog {
    /// Native meeting apps first, then browsers.
    public static let all: [MeetingApp] = nativeApps + browsers

    private static let nativeApps: [MeetingApp] = [
        native("us.zoom.xos", "Zoom"),
        native("com.microsoft.teams2", "Microsoft Teams"),
        native("com.microsoft.teams", "Microsoft Teams"),
        native("com.tinyspeck.slackmacgap", "Slack"),
        native("com.cisco.webexmeetingsapp", "Webex"),
        native("com.webex.meetingmanager", "Webex"),
        native("com.apple.FaceTime", "FaceTime"),
        native("net.whatsapp.WhatsApp", "WhatsApp"),
        native("desktop.WhatsApp", "WhatsApp"),
        native("com.hnc.Discord", "Discord"),
        native("com.skype.skype", "Skype"),
        native("ru.keepcoder.Telegram", "Telegram"),
    ]

    private static let browsers: [MeetingApp] = [
        browser("com.google.Chrome", "Google Chrome"),
        browser("company.thebrowser.Browser", "Arc"),
        browser("company.thebrowser.dia", "Dia"),
        browser("com.apple.Safari", "Safari"),
        // Safari captures the microphone from its shared WebKit GPU process, not from Safari itself.
        browser("com.apple.WebKit.GPU", "Safari"),
        browser("com.microsoft.edgemac", "Microsoft Edge"),
        browser("com.brave.Browser", "Brave"),
        browser("org.mozilla.firefox", "Firefox"),
        browser("com.operasoftware.Opera", "Opera"),
        browser("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    /// Lowercased mic-holding bundle ID → bundle ID of the app that owns the windows.
    static let windowOwnerAliases: [String: String] = [
        "com.apple.webkit.gpu": "com.apple.Safari",
    ]

    /// The catalog entry for a process bundle ID (exact or helper). When several entries match,
    /// the most specific (longest) bundle ID wins.
    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        var best: MeetingApp?
        for app in all where app.matches(bundleID: bundleID) {
            if app.bundleID.count > (best?.bundleID.count ?? -1) {
                best = app
            }
        }
        return best
    }

    /// Meeting apps present among the given process bundle IDs: non-browsers first (catalog order), then browsers. No duplicates.
    public static func candidates(in activeInputBundleIDs: Set<String>) -> [MeetingApp] {
        let present = Set(activeInputBundleIDs.compactMap(app(forBundleID:)))
        let ordered = all.filter(present.contains)
        return ordered.filter { !$0.isBrowser } + ordered.filter(\.isBrowser)
    }

    private static func native(_ bundleID: String, _ name: String) -> MeetingApp {
        MeetingApp(bundleID: bundleID, displayName: name, isBrowser: false)
    }

    private static func browser(_ bundleID: String, _ name: String) -> MeetingApp {
        MeetingApp(bundleID: bundleID, displayName: name, isBrowser: true)
    }
}
