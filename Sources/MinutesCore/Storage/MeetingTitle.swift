import Foundation

/// Derives a human meeting title from a meeting window title.
public enum MeetingTitle {
    /// Separators browsers and meeting apps use between a page title and their own decorations.
    private static let separators = [" - ", " – ", " — ", " | "]

    /// Browsers that append a profile name after their own name ("… - Google Chrome - Work").
    private static let profileBrowsers = ["Google Chrome", "Microsoft Edge"]

    /// Trailing segments that describe the browser, its tab state or the meeting app, never the meeting.
    private static let noiseSuffixes = [
        "Google Chrome", "Chrome", "Arc", "Dia", "Safari", "Microsoft Edge", "Edge", "Brave",
        "Mozilla Firefox", "Firefox", "Opera", "Vivaldi",
        "Audio playing", "Audio muted", "Camera recording", "Microphone recording",
        "Camera and microphone recording", "Camera or microphone recording",
        "Zoom", "Zoom Meeting", "Zoom Workplace", "Microsoft Teams", "Google Meet",
        "Slack", "Webex", "Cisco Webex", "Discord", "FaceTime", "WhatsApp", "Skype", "Telegram",
        "Whereby", "Jitsi Meet",
    ]

    private static let meetPrefixes = ["Meet - ", "Meet – "]

    /// Lowercased titles that only name an app or a generic screen.
    private static let genericTitles: Set<String> = [
        "zoom meeting", "zoom meetings", "zoom", "zoom workplace", "reunión de zoom",
        "microsoft teams", "teams", "meet", "google meet", "slack", "facetime", "whatsapp",
        "webex", "cisco webex", "discord", "skype", "telegram", "whereby", "jitsi meet", "huddle",
        "google chrome", "chrome", "arc", "dia", "safari", "microsoft edge", "brave",
        "firefox", "mozilla firefox", "opera", "vivaldi", "new tab", "nueva pestaña", "untitled",
    ]

    /// Invisible characters some apps embed in window titles (Edge writes "Microsoft\u{200B} Edge").
    private static let invisibleScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// Cleans a window title into a meeting title, nil when generic/empty. Strips prefixes "Meet - "/"Meet – " and suffixes like " - Google Chrome", " – Audio playing", " - Zoom", "| Microsoft Teams"; trailing tab-state emoji ("🔊"); returns nil for generic titles (case-insensitive) such as "Zoom Meeting", "Zoom", "Zoom Workplace", "Microsoft Teams", "Meet", "Google Meet", "Slack", "FaceTime", "WhatsApp", or the app displayName.
    ///
    /// A bare Google Meet room code ("abc-defg-hij") is also treated as generic.
    public static func clean(_ windowTitle: String?, app: MeetingApp) -> String? {
        guard let windowTitle else { return nil }
        var title = String(String.UnicodeScalarView(windowTitle.unicodeScalars.filter { !invisibleScalars.contains($0) }))
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = cutBrowserProfile(title)
        title = stripNoiseSuffixes(title, appName: app.displayName)
        title = stripTrailingEmoji(title)
        title = stripMeetPrefix(title).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !isGeneric(title, appName: app.displayName) else { return nil }
        return title
    }

    /// Meeting services recognised in browser window titles, checked in order.
    private static let browserServices: [(name: String, matches: @Sendable (String) -> Bool)] = [
        ("Google Meet", { $0.hasPrefix("meet - ") || $0.hasPrefix("meet – ") || $0.contains("google meet") }),
        ("Microsoft Teams", { $0.contains("microsoft teams") }),
        ("Zoom", { $0.contains("zoom") }),
        ("Whereby", { $0.contains("whereby") }),
        ("Jitsi Meet", { $0.contains("jitsi") }),
        ("Webex", { $0.contains("webex") }),
        ("Discord", { $0.contains("discord") }),
        ("Slack", { $0.contains("huddle") || $0.contains("slack") }),
    ]

    /// The meeting service shown in a browser window ("Meet - abc-defg-hij" → "Google Meet"), nil when none.
    /// Used as the app name of browser meetings so folders say "(Google Meet)" instead of "(Google Chrome)".
    public static func browserService(fromWindowTitle windowTitle: String?) -> String? {
        guard let lowered = windowTitle?.lowercased() else { return nil }
        return browserServices.first { $0.matches(lowered) }?.name
    }

    /// "Daily - Google Chrome - Work" → "Daily - Google Chrome" (the profile name is not part of the page).
    private static func cutBrowserProfile(_ title: String) -> String {
        for browser in profileBrowsers {
            for separator in separators {
                let marker = separator + browser + separator
                if let range = title.range(of: marker, options: [.caseInsensitive, .backwards]) {
                    return String(title[..<range.lowerBound]) + separator + browser
                }
            }
        }
        return title
    }

    /// Repeatedly removes trailing " - <noise>" segments.
    private static func stripNoiseSuffixes(_ title: String, appName: String) -> String {
        let noise = noiseSuffixes + [appName]
        var result = title
        var changed = true
        while changed {
            changed = false
            for suffix in noise {
                for separator in separators {
                    if let range = result.range(of: separator + suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                        result = String(result[..<range.lowerBound])
                        changed = true
                    }
                }
            }
        }
        return result
    }

    /// Browsers append tab-state emoji to the title ("Meet - abc-defg-hij 🔊").
    private static func stripTrailingEmoji(_ title: String) -> String {
        var scalars = Array(title.unicodeScalars)
        while let last = scalars.last,
              last.properties.isEmojiPresentation || last == "\u{FE0F}" || last.properties.isWhitespace {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func stripMeetPrefix(_ title: String) -> String {
        for prefix in meetPrefixes {
            if let range = title.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                return String(title[range.upperBound...])
            }
        }
        return title
    }

    private static func isGeneric(_ title: String, appName: String) -> Bool {
        let lowered = title.lowercased()
        return genericTitles.contains(lowered)
            || lowered == appName.lowercased()
            || lowered.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil
    }
}
