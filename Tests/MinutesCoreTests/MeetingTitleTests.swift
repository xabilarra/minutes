import Testing
import MinutesCore

@Suite struct MeetingTitleTests {
    private let chrome = MeetingApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", isBrowser: true)
    private let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
    private let teams = MeetingApp(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", isBrowser: false)
    private let discord = MeetingApp(bundleID: "com.hnc.Discord", displayName: "Discord", isBrowser: false)

    @Test func stripsTheMeetPrefixAndBrowserSuffixes() {
        #expect(MeetingTitle.clean("Meet - Cliente X - Google Chrome", app: chrome) == "Cliente X")
        #expect(MeetingTitle.clean("Meet – Sprint review – Audio playing", app: chrome) == "Sprint review")
        #expect(MeetingTitle.clean("Meet - Daily - Audio playing - Google Chrome - Xabi (Trabajo)", app: chrome) == "Daily")
        #expect(MeetingTitle.clean("  Plan Q4 - Cliente  ", app: chrome) == "Plan Q4 - Cliente")
    }

    @Test func stripsMeetingAppSuffixes() {
        #expect(MeetingTitle.clean("Cliente X - Zoom", app: zoom) == "Cliente X")
        #expect(MeetingTitle.clean("Revisión semanal | Microsoft Teams", app: teams) == "Revisión semanal")
    }

    @Test func returnsNilForGenericOrEmptyTitles() {
        let generic = [
            "Zoom Meeting", "zoom", "Zoom Workplace", "Microsoft Teams", "Meet", "Google Meet",
            "Slack", "FaceTime", "WHATSAPP", "Meet - Google Chrome", "Meet - abc-defg-hij - Google Chrome",
        ]
        for title in generic {
            #expect(MeetingTitle.clean(title, app: zoom) == nil, "\(title)")
        }
        #expect(MeetingTitle.clean("Discord", app: discord) == nil)
        #expect(MeetingTitle.clean("   ", app: zoom) == nil)
        #expect(MeetingTitle.clean(nil, app: zoom) == nil)
    }

    @Test func stripsChromeTabStateEmojiSoABareMeetRoomCodeIsGeneric() {
        #expect(MeetingTitle.clean("Meet - abc-defg-hij 🔊", app: chrome) == nil)
        #expect(MeetingTitle.clean("Meet - Revisión semanal 🔊", app: chrome) == "Revisión semanal")
        #expect(MeetingTitle.clean("Daily standup 🔇 - Google Chrome", app: chrome) == "Daily standup")
    }

    @Test func namesTheMeetingServiceOfABrowserWindow() {
        #expect(MeetingTitle.browserService(fromWindowTitle: "Meet - abc-defg-hij 🔊") == "Google Meet")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Revisión semanal - Google Meet") == "Google Meet")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Reunión con Ana | Microsoft Teams") == "Microsoft Teams")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Zoom Meeting") == "Zoom")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Whereby - sala") == "Whereby")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Jitsi Meet") == "Jitsi Meet")
        #expect(MeetingTitle.browserService(fromWindowTitle: "Bandeja de entrada - Gmail") == nil)
        #expect(MeetingTitle.browserService(fromWindowTitle: nil) == nil)
    }
}
