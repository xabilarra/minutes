import Testing
import MinutesCore

@Suite struct MeetingWindowSelectorTests {
    private let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
    private let whatsApp = MeetingApp(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp", isBrowser: false)
    private let chrome = MeetingApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", isBrowser: true)
    private let safariMedia = MeetingApp(bundleID: "com.apple.WebKit.GPU", displayName: "Safari", isBrowser: true)

    private func window(
        _ id: UInt32, _ bundleID: String, _ title: String, _ width: Double = 1000, _ height: Double = 700
    ) -> WindowInfo {
        WindowInfo(windowID: id, bundleID: bundleID, title: title, width: width, height: height)
    }

    @Test func recognizesMeetingLikeTitlesCaseInsensitively() {
        let meetingTitles = [
            "Meet - abc-defg-hij - Google Chrome",
            "Meet – Daily sync",
            "MEET - weekly",
            "Google Meet",
            "Zoom Meeting",
            "Reunión de Zoom",
            "REUNIÓN DE ZOOM",
            "Cliente X | Microsoft Teams",
            "Whereby - Room",
            "Jitsi Meet",
            "Cisco Webex",
            "Huddle in #general",
            "Discord | #voice",
        ]
        for title in meetingTitles {
            #expect(MeetingWindowSelector.isMeetingTitle(title), "\(title)")
        }
        for title in ["Inbox - Gmail", "Meetup - Google Chrome", "Zoom Workplace", "", "Meeting notes"] {
            #expect(!MeetingWindowSelector.isMeetingTitle(title), "\(title)")
        }
    }

    @Test func browserMeetingIsVisibleOnlyForBrowserWindowsWithMeetingTitles() {
        #expect(MeetingWindowSelector.browserMeetingVisible([
            window(1, "com.google.Chrome", "Inbox - Gmail"),
            window(2, "com.google.Chrome", "Meet - abc-defg-hij - Google Chrome"),
        ]))
        #expect(!MeetingWindowSelector.browserMeetingVisible([window(1, "us.zoom.xos", "Zoom Meeting")]))
        #expect(!MeetingWindowSelector.browserMeetingVisible([window(1, "com.google.Chrome", "Inbox - Gmail")]))
        #expect(!MeetingWindowSelector.browserMeetingVisible([window(1, "com.example.notes", "Google Meet")]))
        #expect(!MeetingWindowSelector.browserMeetingVisible([]))
    }

    @Test func selectPrefersAMeetingTitledWindowOverALargerOne() {
        let meeting = window(2, "us.zoom.xos", "Zoom Meeting", 900, 600)
        let windows = [window(1, "us.zoom.xos", "Zoom Workplace", 1400, 900), meeting]
        #expect(MeetingWindowSelector.select(for: zoom, among: windows) == meeting)
    }

    @Test func selectAcceptsCallKeywordsOnlyForNativeApps() {
        let call = window(2, "net.whatsapp.WhatsApp", "Llamada de voz", 400, 600)
        let whatsAppWindows = [window(1, "net.whatsapp.WhatsApp", "WhatsApp", 1200, 800), call]
        #expect(MeetingWindowSelector.select(for: whatsApp, among: whatsAppWindows) == call)

        let largest = window(4, "com.google.Chrome", "Docs - Google Chrome", 1700, 1000)
        let chromeWindows = [window(3, "com.google.Chrome", "Call planning - Google Chrome", 1600, 1000), largest]
        #expect(MeetingWindowSelector.select(for: chrome, among: chromeWindows) == largest)
    }

    @Test func selectIgnoresWindowsBelowMinimumSizeOrOwnedByOtherApps() {
        let workplace = window(3, "us.zoom.xos", "Zoom Workplace", 300, 200)
        let windows = [
            window(1, "us.zoom.xos", "Zoom Meeting", 299, 900),
            window(2, "us.zoom.xos", "Zoom Meeting", 900, 199),
            window(4, "com.google.Chrome", "Zoom Meeting", 2000, 1200),
            workplace,
        ]
        #expect(MeetingWindowSelector.select(for: zoom, among: windows) == workplace)
    }

    @Test func selectFallsBackToTheLargestWindowAndReturnsNilWhenNoneQualify() {
        let large = window(2, "us.zoom.xos", "Settings", 1200, 800)
        #expect(MeetingWindowSelector.select(for: zoom, among: [window(1, "us.zoom.xos", "Chat", 800, 600), large]) == large)
        #expect(MeetingWindowSelector.select(for: zoom, among: [window(1, "us.zoom.xos", "Zoom Meeting", 100, 100)]) == nil)
        #expect(MeetingWindowSelector.select(for: zoom, among: []) == nil)
    }

    @Test func selectFindsSafariWindowsForTheSafariMediaProcess() {
        let meeting = window(2, "com.apple.Safari", "Meet - abc-defg-hij", 1200, 800)
        let windows = [window(1, "com.apple.Safari", "Apple", 1400, 900), meeting]
        #expect(MeetingWindowSelector.select(for: safariMedia, among: windows) == meeting)
    }
}
