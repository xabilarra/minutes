import AVFoundation
import CoreAudio
import Foundation
import os

/// Records the default input device (microphone) to a CAF file: 16 kHz, mono, Int16 PCM.
///
/// Uses an `AVAudioEngine` input-node tap (no voice processing). Alignment follows the same
/// rules as `SystemAudioRecorder`: file time 0 is the reference host time and gaps are
/// filled with silence, using the tap block's `AVAudioTime.hostTime`.
///
/// Device switches (for example AirPods connecting) post `AVAudioEngineConfigurationChange`
/// or change the system default input; either way the engine is recreated, which picks up
/// the current default input, while the same file stays open.
public final class MicrophoneRecorder: @unchecked Sendable {
    private enum State {
        case idle
        case running
        case stopped
    }

    private let outputURL: URL
    private let controlQueue = DispatchQueue(label: "io.github.xabilarra.Minutes.microphone.control")
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "Microphone")

    private let writerLock = NSLock()
    private var writer: AlignedPCMFileWriter? // guarded by writerLock

    // Owned by controlQueue.
    private var state = State.idle
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var defaultInputListener: PropertyListenerToken?
    private var restartScheduled = false
    private var restartAttempts = 0

    private static let tapBufferSize: AVAudioFrameCount = 4_096
    private static let restartDebounce: TimeInterval = 0.3
    private static let restartRetryDelay: TimeInterval = 1
    private static let maxRestartAttempts = 60

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    deinit {
        // No other strong reference exists; tear down directly without hopping queues.
        if state == .running {
            defaultInputListener?.remove()
            stopEngine()
            writer?.finish(endHostTime: HostTime.now())
        }
    }

    /// Starts capturing. File time 0 corresponds to `referenceHostTime`; leading silence is padded.
    /// Throws `permissionDenied` when microphone access was denied. Can only be called once.
    public func start(referenceHostTime: UInt64) throws {
        try controlQueue.sync {
            guard state == .idle else {
                throw CaptureError.unsupported("microphone recorder can only be started once")
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                throw CaptureError.permissionDenied("microphone")
            default:
                break
            }
            let writer = try AlignedPCMFileWriter(
                url: outputURL,
                referenceHostTime: referenceHostTime,
                logCategory: "Microphone"
            )
            writerLock.withLock { self.writer = writer }
            do {
                try startEngine()
                defaultInputListener = try CoreAudioSupport.addListener(
                    to: AudioObjectID(kAudioObjectSystemObject),
                    kAudioHardwarePropertyDefaultInputDevice,
                    queue: controlQueue
                ) { [weak self] in
                    self?.scheduleRestart()
                }
                state = .running
            } catch {
                stopEngine()
                writerLock.withLock {
                    self.writer?.finish(endHostTime: referenceHostTime)
                    self.writer = nil
                }
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
    }

    /// Stops the engine and closes the file. Idempotent and safe from any thread.
    public func stop() {
        controlQueue.sync {
            guard state == .running else {
                state = .stopped
                return
            }
            state = .stopped
            defaultInputListener?.remove()
            defaultInputListener = nil
            stopEngine()
            writerLock.withLock {
                writer?.finish(endHostTime: HostTime.now())
                writer = nil
            }
        }
    }

    // MARK: - Engine (controlQueue)

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.unsupported("no audio input device is available")
        }
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { [weak self] buffer, time in
            self?.handleTap(buffer, time: time)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async { self.scheduleRestart() }
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.coreAudio(
                operation: "AVAudioEngine.start",
                status: OSStatus(truncatingIfNeeded: (error as NSError).code)
            )
        }
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Coalesces bursts of configuration notifications into one engine restart.
    private func scheduleRestart(after delay: TimeInterval = restartDebounce) {
        guard state == .running, !restartScheduled else { return }
        restartScheduled = true
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restart()
        }
    }

    private func restart() {
        restartScheduled = false
        guard state == .running else { return }
        stopEngine()
        writerLock.withLock { writer?.resetConverter() }
        do {
            try startEngine()
            restartAttempts = 0
            logger.info("Microphone capture restarted after a configuration change")
        } catch {
            stopEngine()
            restartAttempts += 1
            logger.error("Microphone restart failed (attempt \(self.restartAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            if restartAttempts < Self.maxRestartAttempts {
                scheduleRestart(after: Self.restartRetryDelay)
            }
        }
    }

    // MARK: - Tap (engine render thread)

    private func handleTap(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let hostTime: UInt64
        if time.isHostTimeValid {
            hostTime = time.hostTime
        } else {
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            hostTime = HostTime.now() &- HostTime.ticks(fromSeconds: duration)
        }
        writerLock.withLock {
            writer?.append(buffer, hostTime: hostTime)
        }
    }
}
