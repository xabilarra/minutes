import Testing
import MinutesCore

@Suite struct MeetingAppCatalogTests {
    private func app(_ bundleID: String) throws -> MeetingApp {
        try #require(MeetingAppCatalog.all.first { $0.bundleID == bundleID }, "missing \(bundleID)")
    }

    @Test func catalogIncludesEveryRequiredMeetingAppAndBrowser() throws {
        let natives: [(String, String)] = [
            ("us.zoom.xos", "Zoom"),
            ("com.microsoft.teams2", "Microsoft Teams"),
            ("com.microsoft.teams", "Microsoft Teams"),
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.cisco.webexmeetingsapp", "Webex"),
            ("com.webex.meetingmanager", "Webex"),
            ("com.apple.FaceTime", "FaceTime"),
            ("net.whatsapp.WhatsApp", "WhatsApp"),
            ("desktop.WhatsApp", "WhatsApp"),
            ("com.hnc.Discord", "Discord"),
            ("com.skype.skype", "Skype"),
            ("ru.keepcoder.Telegram", "Telegram"),
        ]
        let browsers: [(String, String)] = [
            ("com.google.Chrome", "Google Chrome"),
            ("company.thebrowser.Browser", "Arc"),
            ("company.thebrowser.dia", "Dia"),
            ("com.apple.Safari", "Safari"),
            ("com.apple.WebKit.GPU", "Safari"),
            ("com.microsoft.edgemac", "Microsoft Edge"),
            ("com.brave.Browser", "Brave"),
            ("org.mozilla.firefox", "Firefox"),
            ("com.operasoftware.Opera", "Opera"),
            ("com.vivaldi.Vivaldi", "Vivaldi"),
        ]
        for (bundleID, name) in natives {
            let entry = try app(bundleID)
            #expect(entry.displayName == name)
            #expect(!entry.isBrowser)
        }
        for (bundleID, name) in browsers {
            let entry = try app(bundleID)
            #expect(entry.displayName == name)
            #expect(entry.isBrowser)
        }
    }

    @Test func nativeMeetingAppsComeBeforeBrowsers() throws {
        let lastNative = try #require(MeetingAppCatalog.all.lastIndex { !$0.isBrowser })
        let firstBrowser = try #require(MeetingAppCatalog.all.firstIndex { $0.isBrowser })
        #expect(lastNative < firstBrowser)
        #expect(Set(MeetingAppCatalog.all).count == MeetingAppCatalog.all.count)
    }

    @Test func matchesExactBundleIDAndHelpersCaseInsensitively() throws {
        let zoom = try app("us.zoom.xos")
        #expect(zoom.matches(bundleID: "us.zoom.xos"))
        #expect(zoom.matches(bundleID: "US.ZOOM.XOS"))
        #expect(zoom.matches(bundleID: "us.zoom.xos.Helper"))
        #expect(!zoom.matches(bundleID: "us.zoom.xosx"))
        #expect(!zoom.matches(bundleID: "us.zoom"))
    }

    @Test func teamsAndTeams2AreSeparatedByTheDotBoundary() throws {
        let teams = try app("com.microsoft.teams")
        let teams2 = try app("com.microsoft.teams2")
        #expect(!teams.matches(bundleID: "com.microsoft.teams2"))
        #expect(!teams2.matches(bundleID: "com.microsoft.teams"))
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2") == teams2)
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2.helper") == teams2)
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams") == teams)
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams.helper") == teams)
    }

    @Test func appForBundleIDResolvesHelpersAndRejectsUnknownApps() throws {
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.helper") == (try app("com.google.Chrome")))
        #expect(MeetingAppCatalog.app(forBundleID: "com.apple.webkit.gpu")?.displayName == "Safari")
        #expect(MeetingAppCatalog.app(forBundleID: "com.example.recorder") == nil)
    }

    @Test func candidatesListNativeAppsBeforeBrowsersWithoutDuplicates() throws {
        let ids: Set<String> = [
            "com.google.Chrome.helper",
            "com.google.Chrome",
            "us.zoom.xos",
            "com.example.unrelated",
        ]
        #expect(MeetingAppCatalog.candidates(in: ids) == [try app("us.zoom.xos"), try app("com.google.Chrome")])
        #expect(MeetingAppCatalog.candidates(in: []).isEmpty)
    }

    @Test func safariMediaProcessOwnsSafariWindows() throws {
        let safariMedia = try app("com.apple.WebKit.GPU")
        let zoom = try app("us.zoom.xos")
        #expect(safariMedia.ownsWindow(ofBundleID: "com.apple.Safari"))
        #expect(safariMedia.ownsWindow(ofBundleID: "com.apple.WebKit.GPU"))
        #expect(zoom.ownsWindow(ofBundleID: "us.zoom.xos"))
        #expect(!zoom.ownsWindow(ofBundleID: "com.apple.Safari"))
    }
}
