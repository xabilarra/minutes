import AppKit
import MinutesCapture
import MinutesCore
import ServiceManagement
import os

/// Watches for meetings, owns the active recording and hands finished meetings to transcription.
@MainActor
final class RecordingCoordinator: ObservableObject {
    struct ActiveRecording: Equatable {
        let appName: String
        let startedAt: Date
        let trigger: RecordingSession.Trigger
        let hasVideo: Bool
    }

    /// The most recently finished meeting, offered for copying right after the call.
    struct LastMeeting: Equatable {
        enum State: Equatable {
            case transcribing
            case ready
            case failed
        }

        let folder: URL
        var state: State

        var name: String { folder.lastPathComponent }
    }

    struct Permissions: Equatable {
        var microphone = false
        var screenRecording = false
    }

    @Published private(set) var activeRecording: ActiveRecording?
    @Published private(set) var isStarting = false
    @Published private(set) var transcription = TranscriptionPipeline.Status()
    @Published private(set) var lastProblem: String?
    @Published private(set) var hasGroqKey = false
    @Published private(set) var permissions = Permissions()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastMeeting: LastMeeting?

    var isRecording: Bool { session != nil }
    /// Where the copy actions write; tests use a private pasteboard.
    var pasteboard: NSPasteboard = .general
    /// True while a recording runs or a stopped one is still finalizing its files (video remux).
    var needsGracefulTermination: Bool { session != nil || !finalizations.isEmpty }

    private let notifier = Notifier()
    private let indicator = RecordingIndicator()
    private let micMonitor = MicUsageMonitor()
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "coordinator")
    private var detector = MeetingDetector()
    private var session: RecordingSession?
    /// Whether the session ends when its app releases the microphone: automatic recordings, and
    /// manual ones of a meeting app that was using the microphone when they started.
    private var sessionStopsWithMic = false
    private var browserMeetingVisible = false
    private var lastBrowserCheck = Date.distantPast
    private var tasks: [Task<Void, Never>] = []
    private var finalizations: Set<Task<Void, Never>> = []
    private lazy var pipeline = makePipeline()

    // MARK: Lifecycle

    /// - Parameter autoDetect: false disables meeting detection (used by the smoke test).
    func start(autoDetect: Bool = true) {
        AppSettings.registerDefaults()
        notifier.configure()
        indicator.onStop = { [weak self] in
            Task { await self?.stopRecording(manual: true) }
        }
        indicator.onOpenFolder = { [weak self] in self?.openFolder($0) }
        indicator.onCopyTranscript = { [weak self] in self?.copyTranscript(of: $0) ?? false }
        indicator.onCopyPath = { [weak self] in self?.copyTranscriptPath(of: $0) ?? false }
        indicator.onRetry = { [weak self] in self?.retryTranscription(of: $0) }
        refreshGroqKeyState()
        refreshPermissions()

        tasks.append(Task { await self.requestPermissionsIfNeeded() })
        if autoDetect {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            })
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.applyRetention()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        })
        let pipeline = self.pipeline
        loadLastMeeting()
        tasks.append(Task { await pipeline.resumePending() })
    }

    // MARK: Meeting detection

    private func tick() async {
        let monitor = micMonitor
        let activeInputs = await Task.detached(priority: .utility) { monitor.activeInputBundleIDs() }.value
        refreshPermissions()

        if MeetingAppCatalog.candidates(in: activeInputs).contains(where: \.isBrowser) {
            if Date().timeIntervalSince(lastBrowserCheck) >= 5 {
                lastBrowserCheck = Date()
                browserMeetingVisible = MeetingWindowSelector.browserMeetingVisible(await onScreenWindows())
            }
        } else {
            browserMeetingVisible = false
        }

        let event = detector.update(
            activeInputBundleIDs: activeInputs, browserMeetingVisible: browserMeetingVisible, now: Date())
        if session != nil, sessionStopsWithMic {
            indicator.updateStopCountdown(detector.pendingStopDeadline)
        }
        switch event {
        case .started(let app):
            guard AppSettings().autoRecord, session == nil else { return }
            await startRecording(app: app, trigger: .auto)
        case .stopped:
            guard session != nil, sessionStopsWithMic else { return }
            await stopRecording(manual: false)
        case nil:
            break
        }
    }

    private func onScreenWindows() async -> [WindowInfo] {
        guard CapturePermissions.screenRecordingAuthorized() else { return [] }
        do {
            return try await WindowCatalog.onScreenWindows().map {
                WindowInfo(windowID: $0.windowID, bundleID: $0.bundleID, title: $0.title, width: $0.width, height: $0.height)
            }
        } catch {
            logger.error("Listing windows failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Recording

    /// Starts recording the meeting app using the mic, or else the frontmost app (for webinars, ad-hoc calls).
    /// A meeting app using the mic stops by itself when it hangs up; the frontmost-app fallback never does.
    func startManualRecording() {
        Task {
            let monitor = micMonitor
            let activeInputs = await Task.detached(priority: .userInitiated) { monitor.activeInputBundleIDs() }.value
            if let meetingApp = MeetingAppCatalog.candidates(in: activeInputs).first {
                // Only a recording this call started is adopted, never one already running.
                if await startRecording(app: meetingApp, trigger: .manual) {
                    detector.adopt(meetingApp)
                    sessionStopsWithMic = true
                }
                return
            }
            let app = frontmostApp() ?? MeetingApp(bundleID: "", displayName: "Manual", isBrowser: false)
            await startRecording(app: app, trigger: .manual)
        }
    }

    /// Returns whether this call started a recording (false when one is already running or starting, or on failure).
    @discardableResult
    func startRecording(app: MeetingApp, trigger: RecordingSession.Trigger) async -> Bool {
        guard session == nil, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }

        let settings = AppSettings()
        var app = app
        var window: WindowInfo?
        let videoSource = settings.recordVideo ? settings.videoSource : nil
        if !app.bundleID.isEmpty, videoSource != nil || app.isBrowser {
            window = MeetingWindowSelector.select(for: app, among: await onScreenWindows())
        }
        // Browser meetings are named after the service ("Google Meet"), not the browser.
        if app.isBrowser, let service = MeetingTitle.browserService(fromWindowTitle: window?.title) {
            app = MeetingApp(bundleID: app.bundleID, displayName: service, isBrowser: true)
        }
        do {
            let newSession = try await RecordingSession(
                app: app, window: window, video: videoSource, trigger: trigger,
                root: settings.meetingsRoot)
            session = newSession
            sessionStopsWithMic = trigger == .auto
            activeRecording = ActiveRecording(
                appName: app.displayName, startedAt: newSession.startedAt, trigger: trigger,
                hasVideo: newSession.metadata.hasVideo)
            lastProblem = newSession.warnings.isEmpty ? nil : newSession.warnings.joined(separator: " ")
            indicator.showRecording(appName: app.displayName, since: newSession.startedAt)
            return true
        } catch {
            let message = error.localizedDescription
            lastProblem = String(localized: "No se pudo iniciar la grabación: \(message)")
            notifier.problem(String(localized: "No se pudo iniciar la grabación"), detail: message)
            return false
        }
    }

    func stopRecording(manual: Bool) async {
        guard let session else { return }
        self.session = nil
        activeRecording = nil
        if manual {
            detector.suppressUntilMicReleased()
        }
        lastMeeting = LastMeeting(folder: session.folder, state: .transcribing)
        indicator.showTranscribing(folder: session.folder)
        let finalization = Task { _ = await session.stop() }
        finalizations.insert(finalization)
        await finalization.value
        finalizations.remove(finalization)
        if !session.warnings.isEmpty {
            lastProblem = session.warnings.joined(separator: " ")
        }
        await pipeline.enqueue(session.folder)
    }

    /// Stops any recording and waits until every stopped recording has finished writing its files.
    func prepareForTermination() async {
        await stopRecording(manual: true)
        for finalization in finalizations {
            await finalization.value
        }
    }

    private func frontmostApp() -> MeetingApp? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = front.bundleIdentifier
        else { return nil }
        return MeetingAppCatalog.app(forBundleID: bundleID)
            ?? MeetingApp(bundleID: bundleID, displayName: front.localizedName ?? bundleID, isBrowser: false)
    }

    // MARK: Transcription

    private func makePipeline() -> TranscriptionPipeline {
        TranscriptionPipeline(
            root: AppSettings().meetingsRoot,
            apiKeyProvider: { KeychainStore.read(account: KeychainStore.groqAPIKeyAccount) },
            languageProvider: { AppSettings().transcriptionLanguage },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.transcription = status }
            },
            onFinished: { [weak self] folder, failure in
                Task { @MainActor in self?.transcriptionFinished(folder: folder, failure: failure) }
            }
        )
    }

    private func transcriptionFinished(folder: URL, failure: String?) {
        let isLastMeeting = lastMeeting?.folder == folder
        if let failure {
            lastProblem = String(localized: "Falló la transcripción: \(failure)")
            notifier.problem(String(localized: "Falló la transcripción"), detail: failure, folder: folder)
            if isLastMeeting {
                lastMeeting?.state = .failed
                indicator.showTranscriptionFailed(folder: folder)
            }
        } else {
            notifier.transcriptReady(folder: folder)
            if isLastMeeting {
                lastMeeting?.state = .ready
                indicator.showTranscriptReady(folder: folder)
            }
        }
    }

    // MARK: Showcase

    /// Fills the published state with sample data for README screenshots. Nothing is recorded.
    func showcase(_ scene: ShowcaseScene, on screen: NSScreen?) {
        permissions = Permissions(microphone: true, screenRecording: true)
        hasGroqKey = true
        indicator.screen = screen
        let since = Date().addingTimeInterval(-754)
        let folder = FileManager.default.temporaryDirectory.appending(path: ShowcaseScene.meetingName)
        switch scene {
        case .recording, .ending:
            activeRecording = ActiveRecording(
                appName: ShowcaseScene.appName, startedAt: since, trigger: .auto, hasVideo: true)
            indicator.showRecording(appName: ShowcaseScene.appName, since: since)
            if scene == .ending {
                indicator.updateStopCountdown(Date().addingTimeInterval(32))
            }
        case .ready:
            lastMeeting = LastMeeting(folder: folder, state: .ready)
            indicator.showTranscriptReady(folder: folder)
        }
    }

    // MARK: Last meeting

    /// Copies the whole transcript (Markdown) so it can be pasted straight into an agent.
    @discardableResult
    func copyTranscript(of folder: URL) -> Bool {
        let url = folder.appending(path: MeetingFile.transcriptMarkdown.rawValue)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastProblem = String(localized: "Todavía no hay transcripción en esta reunión.")
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// Copies the transcript's file path (and file URL) for agents that read files.
    @discardableResult
    func copyTranscriptPath(of folder: URL) -> Bool {
        let url = folder.appending(path: MeetingFile.transcriptMarkdown.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastProblem = String(localized: "Todavía no hay transcripción en esta reunión.")
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        pasteboard.setString(url.absoluteString, forType: .fileURL)
        return true
    }

    func openFolder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    func retryTranscription(of folder: URL) {
        if lastMeeting?.folder == folder {
            lastMeeting?.state = .transcribing
            indicator.showTranscribing(folder: folder)
        }
        let pipeline = self.pipeline
        Task { await pipeline.enqueue(folder) }
    }

    /// The newest meeting on disk, so the "last meeting" actions survive a relaunch.
    private func loadLastMeeting() {
        let root = AppSettings().meetingsRoot
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let newest = folders
            .compactMap { folder in (try? MetadataStore.read(from: folder)).map { (folder, $0) } }
            .max { $0.1.startedAt < $1.1.startedAt }
        guard let (folder, metadata) = newest, metadata.endedAt != nil else { return }
        let state: LastMeeting.State = switch metadata.transcription.state {
        case .done: .ready
        case .failed: .failed
        case .pending, .transcribing: .transcribing
        }
        lastMeeting = LastMeeting(folder: folder, state: state)
    }

    func retryFailedTranscriptions() {
        let pipeline = self.pipeline
        Task { await pipeline.retryFailed() }
    }

    var isTranscriptionIdle: Bool {
        transcription.active == nil && transcription.queued == 0
    }

    // MARK: Groq key

    func saveGroqKey(_ key: String) throws {
        try KeychainStore.save(key, account: KeychainStore.groqAPIKeyAccount)
        refreshGroqKeyState()
        retryFailedTranscriptions()
    }

    func removeGroqKey() {
        do {
            try KeychainStore.delete(account: KeychainStore.groqAPIKeyAccount)
        } catch {
            lastProblem = String(localized: "No se pudo eliminar la clave de Groq: \(error.localizedDescription)")
        }
        refreshGroqKeyState()
    }

    private func refreshGroqKeyState() {
        hasGroqKey = KeychainStore.read(account: KeychainStore.groqAPIKeyAccount) != nil
    }

    // MARK: Permissions

    private func requestPermissionsIfNeeded() async {
        if !CapturePermissions.microphoneAuthorized() {
            _ = await CapturePermissions.requestMicrophone()
        }
        if AppSettings().recordVideo, !CapturePermissions.screenRecordingAuthorized() {
            CapturePermissions.requestScreenRecording()
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: SettingsKey.didRequestSystemAudio) {
            defaults.set(true, forKey: SettingsKey.didRequestSystemAudio)
            await requestSystemAudioAccess()
        }
        refreshPermissions()
    }

    /// Starts a one-second tap so macOS shows the system-audio permission prompt before the first meeting.
    func requestSystemAudioAccess() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "Minutes-system-audio-check.caf")
        let recorder = SystemAudioRecorder(outputURL: url)
        do {
            try recorder.start(referenceHostTime: HostTime.now())
            try? await Task.sleep(for: .seconds(1))
            recorder.stop()
        } catch {
            lastProblem = String(localized: "Audio del sistema: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func refreshPermissions() {
        let current = Permissions(
            microphone: CapturePermissions.microphoneAuthorized(),
            screenRecording: CapturePermissions.screenRecordingAuthorized())
        if current != permissions { permissions = current }
    }

    enum PrivacyPane: String {
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"
    }

    func openPrivacySettings(_ pane: PrivacyPane = .screenRecording) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Settings actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastProblem = String(localized: "Abrir al iniciar sesión: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Quits (finishing any recording first) and opens Minutes again once this process has exited:
    /// macOS applies a new Screen Recording grant only to a freshly launched app.
    func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(filePath: "/bin/sh")
        reopen.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "relaunch",
            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        do {
            try reopen.run()
        } catch {
            lastProblem = String(localized: "No se pudo reiniciar Minutes: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    func openMeetingsFolder() {
        let root = AppSettings().meetingsRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Moves expired videos to the Trash (recoverable) and records that the meeting no longer has video.
    private func applyRetention() {
        let settings = AppSettings()
        let policy = RetentionPolicy(videoRetentionDays: settings.videoRetentionDays)
        guard policy.videoRetentionDays != nil else { return }
        do {
            for video in try policy.videosToDelete(root: settings.meetingsRoot, now: Date()) {
                let folder = video.deletingLastPathComponent()
                do {
                    try FileManager.default.trashItem(at: video, resultingItemURL: nil)
                } catch {
                    logger.error("Could not trash an expired video: \(error.localizedDescription, privacy: .private)")
                    continue
                }
                if var metadata = try? MetadataStore.read(from: folder) {
                    metadata.hasVideo = false
                    try? MetadataStore.write(metadata, to: folder)
                }
                logger.info("Moved expired video to Trash: \(folder.lastPathComponent, privacy: .private(mask: .hash))")
            }
        } catch {
            logger.error("Retention failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
