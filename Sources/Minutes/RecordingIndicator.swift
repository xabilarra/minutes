import AppKit
import SwiftUI

/// Floating pill under the menu bar. While recording it shows the app, the elapsed time and a Stop
/// button; after the call it stays while the transcript is produced and then offers copying it,
/// copying its path or opening the folder, so the transcript can go straight to an agent. It is
/// visible on every Space and above full-screen meetings, and never takes focus from the call.
@MainActor
final class RecordingIndicator {
    var onStop: (() -> Void)?
    var onOpenFolder: ((URL) -> Void)?
    var onCopyTranscript: ((URL) -> Bool)?
    var onCopyPath: ((URL) -> Bool)?
    var onRetry: ((URL) -> Void)?
    /// Screen to show the pill on; nil follows the screen in use.
    var screen: NSScreen?

    /// How long the finished or failed state stays before hiding by itself.
    private static let resultDuration: Double = 120

    private let model = IndicatorModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<IndicatorView>?
    private var hideTask: Task<Void, Never>?

    /// The panel's current size, nil before it is first shown.
    var panelSize: NSSize? { panel?.frame.size }
    /// The size the pill's content asks for right now.
    var contentFittingSize: NSSize? { hostingView == nil ? nil : measuredContentSize() }
    /// Whether the content may resize the panel by itself (it must not: only `place` sizes it).
    var contentResizesPanel: Bool { !(hostingView?.sizingOptions.isEmpty ?? true) }

    func showRecording(appName: String, since: Date) {
        show(.recording(appName: appName, since: since, stopDeadline: nil), hideAfter: nil)
    }

    /// While recording: a deadline means the meeting app released the microphone (the user probably
    /// hung up) and the recording stops then; nil means the call is still going.
    func updateStopCountdown(_ deadline: Date?) {
        guard case .recording(let appName, let since, let current) = model.state, current != deadline else { return }
        show(.recording(appName: appName, since: since, stopDeadline: deadline), hideAfter: nil)
    }

    func showTranscribing(folder: URL) {
        show(.transcribing(folder), hideAfter: nil)
    }

    /// Skipped while a new recording is running so its Stop button stays on screen.
    func showTranscriptReady(folder: URL) {
        if case .recording = model.state { return }
        show(.ready(folder), hideAfter: Self.resultDuration)
    }

    func showTranscriptionFailed(folder: URL) {
        if case .recording = model.state { return }
        show(.failed(folder), hideAfter: Self.resultDuration)
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        model.state = .hidden
    }

    private func show(_ state: IndicatorModel.State, hideAfter seconds: Double?) {
        hideTask?.cancel()
        model.state = state
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Re-assigning the root view updates the hierarchy now, so the size below fits the new state.
        hostingView?.rootView = makeRootView()
        place(panel)
        panel.orderFrontRegardless()
        if let seconds {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: makeRootView())
        // Only `place` sizes the panel. Letting the hosting view resize the window whenever the text
        // width changed crashed AppKit with an endless Update Constraints loop (2026-10-19).
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }

    private func makeRootView() -> IndicatorView {
        IndicatorView(
            model: model,
            actions: IndicatorActions(
                stop: { [weak self] in self?.onStop?() },
                openFolder: { [weak self] in self?.onOpenFolder?($0) },
                copyTranscript: { [weak self] in self?.onCopyTranscript?($0) ?? false },
                copyPath: { [weak self] in self?.onCopyPath?($0) ?? false },
                retry: { [weak self] in self?.onRetry?($0) },
                close: { [weak self] in self?.hide() }))
    }

    /// The content's ideal size, measured apart: the panel's hosting view does not report a size,
    /// because it must never resize the panel by itself.
    private func measuredContentSize() -> NSSize {
        NSHostingController(rootView: makeRootView())
            .sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    /// Top centre of the screen in use, just below the menu bar (and the notch).
    private func place(_ panel: NSPanel) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = measuredContentSize()
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10, width: size.width, height: size.height),
            display: true)
    }
}

private final class IndicatorModel: ObservableObject {
    enum State: Equatable {
        case hidden
        case recording(appName: String, since: Date, stopDeadline: Date?)
        case transcribing(URL)
        case ready(URL)
        case failed(URL)
    }

    @Published var state: State = .hidden
}

private struct IndicatorActions {
    let stop: () -> Void
    let openFolder: (URL) -> Void
    let copyTranscript: (URL) -> Bool
    let copyPath: (URL) -> Bool
    let retry: (URL) -> Void
    let close: () -> Void
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let actions: IndicatorActions
    @State private var pulse = false
    @State private var copied: CopyTarget?

    private enum CopyTarget { case transcript, path }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .fixedSize()
        .onChange(of: model.state) { copied = nil }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .recording(_, _, let stopDeadline?):
            Circle()
                .fill(.orange)
                .frame(width: 9, height: 9)
            Text("¿Has colgado?").font(.callout.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Se detiene en \(Self.remaining(until: stopDeadline, now: context.date))")
                    .font(.callout.monospacedDigit())
            }
            .fixedSize()
            Button("Detener ya", action: actions.stop)
                .buttonStyle(PillButtonStyle(tint: .red))
        case .recording(let appName, let since, nil):
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text("Grabando").font(.callout.weight(.semibold))
            Text(appName).font(.callout).foregroundStyle(.secondary)
            // Sized for "0:00:00" so the pill keeps its width when the recording passes an hour.
            Text(verbatim: "0:00:00").font(.callout.monospacedDigit()).hidden()
                .overlay(alignment: .leading) {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(Self.elapsed(from: since, to: context.date)).font(.callout.monospacedDigit())
                            .fixedSize()
                    }
                }
            Button("Detener", action: actions.stop)
                .buttonStyle(PillButtonStyle(tint: .red))
        case .transcribing(let folder):
            ProgressView().controlSize(.small)
            Text("Guardando y transcribiendo…").font(.callout)
            Button("Abrir carpeta") { actions.openFolder(folder) }
                .buttonStyle(PillButtonStyle())
        case .ready(let folder):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Transcripción lista").font(.callout.weight(.semibold))
            Button(copied == .transcript ? "Copiada ✓" : "Copiar texto") {
                if actions.copyTranscript(folder) { copied = .transcript }
            }
            .buttonStyle(PillButtonStyle(tint: PillButtonStyle.brand))
            Button(copied == .path ? "Ruta copiada ✓" : "Copiar ruta") {
                if actions.copyPath(folder) { copied = .path }
            }
            .buttonStyle(PillButtonStyle())
            Button("Abrir carpeta") { actions.openFolder(folder) }
                .buttonStyle(PillButtonStyle())
            closeButton
        case .failed(let folder):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Falló la transcripción").font(.callout.weight(.semibold))
            Button("Reintentar") { actions.retry(folder) }
                .buttonStyle(PillButtonStyle())
            Button("Abrir carpeta") { actions.openFolder(folder) }
                .buttonStyle(PillButtonStyle())
            closeButton
        case .hidden:
            EmptyView()
        }
    }

    private var closeButton: some View {
        Button(action: actions.close) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(Text("Cerrar"))
    }

    private static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Buttons with their own colours: the panel never becomes key, so system button styles would
/// always draw in their inactive grey.
private struct PillButtonStyle: ButtonStyle {
    static let brand = Color(red: 0.42, green: 0.25, blue: 0.75)

    /// nil draws a neutral button.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(tint == nil ? .regular : .semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint ?? Color.primary.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
