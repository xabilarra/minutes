import AppKit
import SwiftUI

/// Main window: what Minutes is doing and what it still needs, independent of the menu bar icon.
struct StatusView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @AppStorage(SettingsKey.autoRecord) private var autoRecord = true
    @AppStorage(SettingsKey.recordVideo) private var recordVideo = true
    @AppStorage(SettingsKey.videoSource) private var videoSource: VideoSource = .focus
    @AppStorage(SettingsKey.videoRetentionDays) private var videoRetentionDays = 30
    @AppStorage(SettingsKey.transcriptionLanguage) private var transcriptionLanguage = TranscriptionLanguage.systemDefault
    @AppStorage(SettingsKey.transcriptionVocabulary) private var transcriptionVocabulary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let last = coordinator.lastMeeting {
                lastMeetingBox(last)
            }
            GroupBox("Grabación") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Grabar reuniones automáticamente", isOn: $autoRecord)
                    Toggle("Grabar vídeo", isOn: $recordVideo)
                    Picker("Vídeo", selection: $videoSource) {
                        Text("Ventana activa").tag(VideoSource.focus)
                        Text("Ventana de la reunión").tag(VideoSource.window)
                        Text("Pantalla completa").tag(VideoSource.display)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!recordVideo)
                    Text(videoSourceDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Idioma de la transcripción", selection: $transcriptionLanguage) {
                        Text("Detectar automáticamente").tag(TranscriptionLanguage.automatic)
                        ForEach(TranscriptionLanguage.options, id: \.code) { option in
                            Text(verbatim: option.name).tag(option.code)
                        }
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 4) {
                        // Outside a Form macOS hides a TextField's own label, so it is shown like the pickers'.
                        HStack {
                            Text("Vocabulario")
                            TextField("Vocabulario", text: $transcriptionVocabulary, prompt: Text("p. ej. Groq, Whisper, Ane Etxeberria"))
                                .labelsHidden()
                        }
                        Text("Nombres y términos bien escritos, separados por comas. Minutes corrige en la transcripción las palabras que suenan igual.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            // Without it the wrapped text keeps resizing the window until AppKit aborts.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Conservar vídeos", selection: $videoRetentionDays) {
                        Text("7 días").tag(7)
                        Text("30 días").tag(30)
                        Text("90 días").tag(90)
                        Text("Siempre").tag(0)
                    }
                    .fixedSize()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Configuración") {
                VStack(alignment: .leading, spacing: 12) {
                    SetupRow(
                        title: "Micrófono", state: coordinator.permissions.microphone,
                        detail: "Graba lo que dices."
                    ) {
                        Button("Abrir Ajustes…") { coordinator.openPrivacySettings(.microphone) }
                    }
                    SetupRow(
                        title: "Grabación de pantalla y audio del sistema", state: coordinator.permissions.screenRecording,
                        detail: "Vídeo de la ventana de la reunión y detección de reuniones en el navegador. Vuelve a abrir Minutes después de activarlo."
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Abrir Ajustes…") { coordinator.openPrivacySettings(.screenRecording) }
                            Button("Reiniciar Minutes") { coordinator.relaunch() }
                        }
                    }
                    SetupRow(
                        title: "Audio del sistema", state: nil,
                        detail: "Lo que dicen los demás. macOS lo pide la primera vez que Minutes escucha."
                    ) {
                        Button("Solicitar acceso") { Task { await coordinator.requestSystemAudioAccess() } }
                    }
                    SetupRow(
                        title: "Clave de API de Groq", state: coordinator.hasGroqKey,
                        detail: coordinator.hasGroqKey ? "Guardada en tu Llavero." : "Necesaria para transcribir las grabaciones."
                    ) {
                        EmptyView()
                    }
                    if !coordinator.hasGroqKey {
                        GroqKeyForm(coordinator: coordinator) {}
                    }
                }
                .padding(6)
            }
            activity
            HStack(alignment: .top) {
                Button("Abrir carpeta de reuniones") { coordinator.openMeetingsFolder() }
                Spacer()
                Text("Minutes vive en la barra de menús (icono de onda). Si tienes muchos iconos puede quedar oculto tras el notch; abre Minutes otra vez para recuperar esta ventana.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func lastMeetingBox(_ last: RecordingCoordinator.LastMeeting) -> some View {
        GroupBox("Última reunión") {
            VStack(alignment: .leading, spacing: 8) {
                Text(last.name).font(.headline)
                switch last.state {
                case .transcribing:
                    Label("Guardando y transcribiendo…", systemImage: "ellipsis.circle")
                case .ready:
                    Label {
                        Text("Transcripción lista")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                case .failed:
                    Label("Falló la transcripción", systemImage: "exclamationmark.triangle.fill")
                }
                HStack {
                    Button("Copiar transcripción") { coordinator.copyTranscript(of: last.folder) }
                        .buttonStyle(.borderedProminent)
                        .disabled(last.state != .ready)
                    Button("Copiar ruta") { coordinator.copyTranscriptPath(of: last.folder) }
                        .disabled(last.state != .ready)
                    Button("Abrir carpeta") { coordinator.openFolder(last.folder) }
                    if last.state == .failed {
                        Button("Reintentar") { coordinator.retryTranscription(of: last.folder) }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var videoSourceDescription: LocalizedStringKey {
        switch videoSource {
        case .focus: "Graba la ventana que estás mirando, empezando por la reunión: incluye lo que presentes desde otras ventanas."
        case .window: "Graba solo la ventana de la reunión, incluido lo que compartan los demás."
        case .display: "Graba toda la pantalla donde está la reunión, incluido lo que presentes tú."
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Minutes").font(.title2.bold())
                Text(stateLine).foregroundStyle(.secondary)
            }
            Spacer()
            if coordinator.activeRecording != nil {
                Button("Detener grabación") { Task { await coordinator.stopRecording(manual: true) } }
            } else {
                Button("Grabar ahora") { coordinator.startManualRecording() }
                    .disabled(coordinator.isStarting)
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if let active = coordinator.transcription.active {
            Label("Transcribiendo \(active)…", systemImage: "ellipsis.circle")
        }
        if coordinator.transcription.failed > 0 {
            HStack {
                Label("Transcripciones fallidas: \(coordinator.transcription.failed)", systemImage: "exclamationmark.triangle")
                Button("Reintentar") { coordinator.retryFailedTranscriptions() }
            }
        }
        if let problem = coordinator.lastProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateLine: String {
        if let recording = coordinator.activeRecording {
            let time = recording.startedAt.formatted(date: .omitted, time: .shortened)
            return recording.hasVideo
                ? String(localized: "Grabando \(recording.appName) desde las \(time)")
                : String(localized: "Grabando \(recording.appName) desde las \(time) (solo audio)")
        }
        return autoRecord ? String(localized: "Vigilando reuniones") : String(localized: "Grabación automática desactivada")
    }
}

/// One setup requirement: granted (true), missing (false) or not checkable (nil).
private struct SetupRow<Action: View>: View {
    let title: LocalizedStringKey
    let state: Bool?
    let detail: LocalizedStringKey
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state != true {
                action()
            }
        }
    }

    private var symbol: String {
        switch state {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case true?: .green
        case false?: .red
        case nil: .secondary
        }
    }
}
