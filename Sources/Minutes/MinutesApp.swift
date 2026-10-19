import AppKit
import ServiceManagement
import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator, showWindow: appDelegate.showStatusWindow)
        } label: {
            MenuBarLabel(coordinator: appDelegate.coordinator)
        }

        Window("Clave de Groq", id: GroqKeyView.windowID) {
            GroqKeyView(coordinator: appDelegate.coordinator)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = RecordingCoordinator()
    private var statusWindow: NSWindow?
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch Apple event is only available while launching.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let scene = ShowcaseScene(arguments: CommandLine.arguments) {
            // Screenshots look best on the sharpest screen.
            let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
            AppSettings.registerDefaults()
            coordinator.showcase(scene, on: screen)
            showStatusWindow(on: screen)
            return
        }
        let smokeTest = SmokeTest(arguments: CommandLine.arguments)
        coordinator.start(autoDetect: smokeTest == nil)
        smokeTest?.run(with: coordinator)
        if smokeTest == nil, !isLoginLaunch {
            showStatusWindow()
        }
    }

    /// Opening Minutes again (Finder, Spotlight, Launchpad) shows its window, even if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusWindow()
        return false
    }

    /// Finalizes in-progress and stopping recordings before quitting so no audio or video is lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.needsGracefulTermination else { return .terminateNow }
        Task {
            await coordinator.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func showStatusWindow() {
        showStatusWindow(on: nil)
    }

    /// Centers the window on `screen`, or else on the screen under the pointer, every time it is
    /// shown: with several displays the user is looking at the one they just clicked on.
    private func showStatusWindow(on screen: NSScreen?) {
        let window = statusWindow ?? makeStatusWindow()
        statusWindow = window
        if !window.isVisible, let target = screen ?? Self.screenUnderPointer() {
            let visible = target.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeStatusWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: StatusView(coordinator: coordinator)))
        window.title = "Minutes"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        return window
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// Login launches stay silent in the menu bar. Login items registered through SMAppService
    /// do not always carry the login Apple event, so a launch right after boot counts too.
    private var isLoginLaunch: Bool {
        launchedAsLoginItem
            || (SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 180)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.activeRecording != nil {
            Image(systemName: "record.circle")
        } else if !coordinator.isTranscriptionIdle {
            Image(systemName: "ellipsis.circle")
        } else {
            Image(systemName: "waveform")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var coordinator: RecordingCoordinator
    let showWindow: () -> Void
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.autoRecord) private var autoRecord = true
    @AppStorage(SettingsKey.recordVideo) private var recordVideo = true
    @AppStorage(SettingsKey.videoRetentionDays) private var videoRetentionDays = 30
    @AppStorage(SettingsKey.videoSource) private var videoSource: VideoSource = .window
    @AppStorage(SettingsKey.transcriptionLanguage) private var transcriptionLanguage = TranscriptionLanguage.systemDefault

    var body: some View {
        if let recording = coordinator.activeRecording {
            let time = recording.startedAt.formatted(date: .omitted, time: .shortened)
            if recording.hasVideo {
                Text("Grabando \(recording.appName) desde las \(time)")
            } else {
                Text("Grabando \(recording.appName) desde las \(time) (solo audio)")
            }
            Button("Detener grabación") {
                Task { await coordinator.stopRecording(manual: true) }
            }
            .keyboardShortcut(".")
        } else {
            if autoRecord {
                Text("Vigilando reuniones")
            } else {
                Text("Grabación automática desactivada")
            }
            Button("Grabar ahora") { coordinator.startManualRecording() }
                .disabled(coordinator.isStarting)
        }

        if let active = coordinator.transcription.active {
            Text("Transcribiendo \(active)…")
        }
        if coordinator.transcription.queued > 0 {
            Text("\(coordinator.transcription.queued) pendientes de transcribir")
        }
        if coordinator.transcription.failed > 0 {
            Button("Reintentar transcripciones fallidas (\(coordinator.transcription.failed))") {
                coordinator.retryFailedTranscriptions()
            }
        }
        if let problem = coordinator.lastProblem {
            Text(problem)
        }
        Button("Abrir carpeta de reuniones") { coordinator.openMeetingsFolder() }
        Button("Abrir ventana de Minutes…") { showWindow() }

        if let last = coordinator.lastMeeting {
            Divider()
            Text("Última reunión: \(last.name)")
            Button("Copiar transcripción") { coordinator.copyTranscript(of: last.folder) }
                .disabled(last.state != .ready)
            Button("Copiar ruta de la transcripción") { coordinator.copyTranscriptPath(of: last.folder) }
                .disabled(last.state != .ready)
            Button("Abrir carpeta de la reunión") { coordinator.openFolder(last.folder) }
            if last.state == .failed {
                Button("Reintentar transcripción") { coordinator.retryTranscription(of: last.folder) }
            }
        }

        Divider()

        Toggle("Grabar reuniones automáticamente", isOn: $autoRecord)
        Toggle("Grabar vídeo", isOn: $recordVideo)
        Picker("Vídeo", selection: $videoSource) {
            Text("Ventana de la reunión").tag(VideoSource.window)
            Text("Pantalla completa").tag(VideoSource.display)
        }
        .disabled(!recordVideo)
        Picker("Idioma de la transcripción", selection: $transcriptionLanguage) {
            Text("Detectar automáticamente").tag(TranscriptionLanguage.automatic)
            ForEach(TranscriptionLanguage.options, id: \.code) { option in
                Text(verbatim: option.name).tag(option.code)
            }
        }
        Picker("Conservar vídeos", selection: $videoRetentionDays) {
            Text("7 días").tag(7)
            Text("30 días").tag(30)
            Text("90 días").tag(90)
            Text("Siempre").tag(0)
        }
        Button(coordinator.hasGroqKey ? "Clave de Groq… (guardada)" : "Configurar clave de Groq…") {
            NSApp.activate()
            openWindow(id: GroqKeyView.windowID)
        }
        Toggle("Abrir al iniciar sesión", isOn: Binding(
            get: { coordinator.launchAtLogin },
            set: { coordinator.setLaunchAtLogin($0) }
        ))

        Divider()

        Menu("Permisos") {
            Text(coordinator.permissions.microphone ? "Micrófono: permitido" : "Micrófono: no permitido")
            Text(coordinator.permissions.screenRecording ? "Grabación de pantalla: permitida" : "Grabación de pantalla: no permitida")
            Button("Solicitar acceso al audio del sistema") {
                Task { await coordinator.requestSystemAudioAccess() }
            }
            Button("Abrir ajustes de privacidad…") { coordinator.openPrivacySettings() }
        }
        Button("Salir de Minutes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct GroqKeyView: View {
    static let windowID = "groq-key"

    @ObservedObject var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var removed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clave de API de Groq").font(.headline)
            Text("Se guarda en el Llavero de macOS y solo se usa para transcribir las grabaciones con whisper-large-v3.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroqKeyForm(coordinator: coordinator) { dismiss() }
            if removed {
                Text("Clave eliminada.").font(.callout)
            }
            HStack {
                if coordinator.hasGroqKey {
                    Button("Eliminar clave", role: .destructive) {
                        coordinator.removeGroqKey()
                        removed = true
                    }
                }
                Spacer()
                Button("Cerrar") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Secure entry for the Groq key; validates the format before anything reaches the Keychain.
struct GroqKeyForm: View {
    @ObservedObject var coordinator: RecordingCoordinator
    let onSaved: () -> Void
    @State private var key = ""
    @State private var message: String?

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("gsk_…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Guardar", action: save)
                    .disabled(trimmedKey.isEmpty)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        guard trimmedKey.hasPrefix("gsk_") else {
            message = String(localized: "Eso no parece una clave de Groq (empiezan por gsk_). No se ha guardado nada.")
            return
        }
        do {
            try coordinator.saveGroqKey(trimmedKey)
            key = ""
            message = nil
            onSaved()
        } catch {
            message = String(localized: "No se pudo guardar la clave: \(error.localizedDescription)")
        }
    }
}
