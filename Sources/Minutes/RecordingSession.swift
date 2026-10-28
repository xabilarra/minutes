import CoreGraphics
import Foundation
import MinutesCapture
import MinutesCore
import os

/// One in-progress recording: its folder, the three recorders and the meeting metadata.
///
/// Both audio tracks and the video share `referenceHostTime` as their time origin, so transcript
/// timestamps (audio time) map onto the video through `videoOffsetSeconds`.
@MainActor
final class RecordingSession {
    enum Trigger: String {
        case auto
        case manual
    }

    enum SessionError: LocalizedError {
        case noAudio(String)

        var errorDescription: String? {
            switch self {
            case .noAudio(let detail): return String(localized: "No se pudo iniciar ninguna pista de audio. \(detail)")
            }
        }
    }

    let folder: URL
    let app: MeetingApp
    let trigger: Trigger
    let startedAt: Date
    private(set) var metadata: MeetingMetadata
    /// Non-fatal problems (a track or the video could not start, or the video was interrupted).
    private(set) var warnings: [String]

    private let referenceHostTime: UInt64
    private let microphone: MicrophoneRecorder
    private let systemAudio: SystemAudioRecorder
    private let video: WindowVideoRecorder?
    private let focusTracker: FocusTracker?
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "session")

    /// - Parameters:
    ///   - window: the meeting window; its title names the meeting.
    ///   - video: what to record as video, nil for audio only. `.focus` and `.window` need `window`;
    ///     `.display` and `.activeDisplay` start on the display showing `window` (the main display without one).
    init(app: MeetingApp, window: WindowInfo?, video videoSource: VideoSource?, trigger: Trigger, root: URL) async throws {
        let fileManager = FileManager.default
        let startedAt = Date()
        let title = MeetingTitle.clean(window?.title, app: app)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folderName = MeetingFolder.folderName(start: startedAt, title: title, appName: app.displayName)
        let folder = MeetingFolder.uniqueURL(in: root, name: folderName)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)

        // Written before any recorder starts, so a meeting folder always has meta.json.
        var metadata = MeetingMetadata(
            appName: app.displayName,
            appBundleID: app.bundleID.isEmpty ? nil : app.bundleID,
            title: title,
            windowTitle: window?.title,
            trigger: trigger.rawValue,
            startedAt: startedAt,
            hasVideo: false
        )
        do {
            try MetadataStore.write(metadata, to: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }

        let referenceHostTime = HostTime.now()
        let microphone = MicrophoneRecorder(outputURL: folder.appending(path: MeetingFile.micRaw.rawValue))
        let systemAudio = SystemAudioRecorder(outputURL: folder.appending(path: MeetingFile.systemRaw.rawValue))
        var warnings: [String] = []
        var startedTracks = 0
        do {
            try microphone.start(referenceHostTime: referenceHostTime)
            startedTracks += 1
        } catch {
            warnings.append(String(localized: "Micrófono: \(error.localizedDescription)"))
        }
        do {
            try systemAudio.start(referenceHostTime: referenceHostTime)
            startedTracks += 1
        } catch {
            warnings.append(String(localized: "Audio del sistema: \(error.localizedDescription)"))
        }
        guard startedTracks > 0 else {
            microphone.stop()
            systemAudio.stop()
            try? fileManager.removeItem(at: folder)
            throw SessionError.noAudio(warnings.joined(separator: " "))
        }

        var video: WindowVideoRecorder?
        var focusTracker: FocusTracker?
        if let videoSource, videoSource == .display || videoSource == .activeDisplay || window != nil {
            let recorder = WindowVideoRecorder(outputURL: folder.appending(path: MeetingFile.video.rawValue))
            do {
                switch videoSource {
                case .activeDisplay:
                    try await recorder.start(followingDisplayFrom: window?.windowID)
                    focusTracker = FocusTracker(recorder: recorder, displayID: recorder.displayID ?? CGMainDisplayID())
                case .display:
                    try await recorder.start(displayContainingWindowID: window?.windowID)
                case .window:
                    if let window { try await recorder.start(windowID: window.windowID) }
                case .focus:
                    if let window {
                        try await recorder.start(followingFocusFrom: window.windowID)
                        focusTracker = FocusTracker(recorder: recorder, meetingWindowID: window.windowID)
                    }
                }
                video = recorder
            } catch {
                warnings.append(String(localized: "Vídeo: \(error.localizedDescription)"))
            }
        }

        self.folder = folder
        self.app = app
        self.trigger = trigger
        self.startedAt = startedAt
        self.referenceHostTime = referenceHostTime
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.video = video
        self.focusTracker = focusTracker
        self.warnings = warnings
        metadata.hasVideo = video != nil
        self.metadata = metadata
        if video != nil {
            do {
                try MetadataStore.write(metadata, to: folder)
            } catch {
                logger.error("Could not update meta.json: \(error.localizedDescription, privacy: .private)")
            }
        }

        video?.onInterrupted = { [logger] error in
            logger.notice("Video capture interrupted: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("Recording started: \(folder.lastPathComponent, privacy: .private(mask: .hash))")
    }

    /// Stops every recorder and writes the final metadata. Audio stays as CAF until transcription succeeds.
    func stop() async -> MeetingMetadata {
        microphone.stop()
        systemAudio.stop()
        focusTracker?.stop()
        var videoResult: VideoRecordingResult?
        if let video {
            do {
                videoResult = try await video.stop()
            } catch {
                warnings.append(String(localized: "Vídeo: \(error.localizedDescription)"))
            }
        }

        let endedAt = Date()
        metadata.endedAt = endedAt
        metadata.durationSeconds = endedAt.timeIntervalSince(startedAt)
        metadata.hasVideo = videoResult != nil
        if let firstFrame = videoResult?.firstFrameHostTime {
            metadata.videoOffsetSeconds = HostTime.seconds(from: referenceHostTime, to: firstFrame)
        }
        do {
            try MetadataStore.write(metadata, to: folder)
        } catch {
            logger.error("Could not write meta.json: \(error.localizedDescription, privacy: .private)")
        }
        logger.info("Recording stopped: \(self.folder.lastPathComponent, privacy: .private(mask: .hash))")
        return metadata
    }
}
