import AVFAudio
import CoreAudio
import Foundation
import os

/// Records all system audio output (a global Core Audio process tap that excludes this
/// process) to a CAF file: 16 kHz, mono, Int16 PCM.
///
/// Pipeline: `CATapDescription` → process tap → private aggregate device (main sub-device =
/// current default output, tap list = our tap) → block IOProc on a dedicated serial queue →
/// `AVAudioConverter` → `AlignedPCMFileWriter`.
///
/// When the default output device or the tap/aggregate sample rate changes, the tap,
/// aggregate device and converter are rebuilt while the same file stays open; the host-time
/// padding rule fills the gap so the track stays aligned.
///
/// Threading: `controlQueue` owns the Core Audio objects and the lifecycle; `ioQueue` runs
/// the IOProc; `writerLock` serializes every access to the file writer.
public final class SystemAudioRecorder: @unchecked Sendable {
    private enum State {
        case idle
        case running
        case stopped
    }

    /// Core Audio objects of one capture chain, destroyed in reverse creation order.
    private struct CaptureChain {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var isStarted = false
        var listeners: [PropertyListenerToken] = []
        var sampleRate: Double = 0
    }

    private let outputURL: URL
    private let controlQueue = DispatchQueue(label: "io.github.xabilarra.Minutes.systemAudio.control")
    private let ioQueue = DispatchQueue(label: "io.github.xabilarra.Minutes.systemAudio.io", qos: .userInteractive)
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "SystemAudio")

    private let writerLock = NSLock()
    private var writer: AlignedPCMFileWriter? // guarded by writerLock

    // Owned by controlQueue.
    private var state = State.idle
    private var chain: CaptureChain?
    private var defaultOutputListener: PropertyListenerToken?
    private var rebuildScheduled = false
    private var rebuildAttempts = 0

    private static let rebuildDebounce: TimeInterval = 0.3
    private static let rebuildRetryDelay: TimeInterval = 2
    private static let maxRebuildAttempts = 30

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    deinit {
        // No other strong reference exists, so no queue work can be running on our behalf.
        // The last reference may be released from inside an IO callback, so never sync onto ioQueue here.
        if state == .running {
            defaultOutputListener?.remove()
            if let chain { destroy(chain, drainingIO: false) }
            writer?.finish(endHostTime: HostTime.now())
        }
    }

    /// Starts capturing. File time 0 corresponds to `referenceHostTime`; leading silence is padded.
    /// Can only be called once per instance.
    public func start(referenceHostTime: UInt64) throws {
        try controlQueue.sync {
            guard state == .idle else {
                throw CaptureError.unsupported("system audio recorder can only be started once")
            }
            let writer = try AlignedPCMFileWriter(
                url: outputURL,
                referenceHostTime: referenceHostTime,
                logCategory: "SystemAudio"
            )
            writerLock.withLock { self.writer = writer }
            do {
                chain = try buildChain()
                defaultOutputListener = try CoreAudioSupport.addListener(
                    to: AudioObjectID(kAudioObjectSystemObject),
                    kAudioHardwarePropertyDefaultOutputDevice,
                    queue: controlQueue
                ) { [weak self] in
                    self?.scheduleRebuild()
                }
                state = .running
            } catch {
                if let chain { destroy(chain) }
                chain = nil
                writerLock.withLock {
                    self.writer?.finish(endHostTime: referenceHostTime)
                    self.writer = nil
                }
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
    }

    /// Stops IO, destroys the IOProc, aggregate device and tap, and closes the file. Idempotent.
    public func stop() {
        controlQueue.sync {
            guard state == .running else {
                state = .stopped
                return
            }
            state = .stopped
            defaultOutputListener?.remove()
            defaultOutputListener = nil
            if let chain { destroy(chain) }
            chain = nil
            writerLock.withLock {
                writer?.finish(endHostTime: HostTime.now())
                writer = nil
            }
        }
    }

    // MARK: - Capture chain (controlQueue)

    private func buildChain() throws -> CaptureChain {
        var chain = CaptureChain()
        do {
            // 1. Process tap: every process except this one, downmixed to mono, not muted.
            let ownProcess = (try? CoreAudioSupport.processObject(for: getpid())) ?? AudioObjectID(kAudioObjectUnknown)
            let excluded = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            description.uuid = UUID()
            description.name = "Minutes system audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tapID = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
            guard tapStatus == noErr else {
                throw CaptureError.coreAudio(operation: "AudioHardwareCreateProcessTap", status: tapStatus)
            }
            chain.tapID = tapID

            var streamDescription = try CoreAudioSupport.value(
                of: tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()
            )
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.unsupported("the system audio tap reported an unusable format")
            }
            chain.sampleRate = streamDescription.mSampleRate

            // 2. Private aggregate device clocked by the current output device, carrying the tap.
            let outputUID = try CoreAudioSupport.deviceUID(try CoreAudioSupport.defaultOutputDevice())
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Minutes System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ],
                ],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            guard aggregateStatus == noErr else {
                throw CaptureError.coreAudio(operation: "AudioHardwareCreateAggregateDevice", status: aggregateStatus)
            }
            chain.aggregateID = aggregateID

            // 3. IOProc on the dedicated serial queue; buffers are only valid during the call.
            var procID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [weak self] _, inputData, inputTime, _, _ in
                self?.handleInput(inputData, time: inputTime, format: tapFormat)
            }
            guard procStatus == noErr, let procID else {
                throw CaptureError.coreAudio(operation: "AudioDeviceCreateIOProcIDWithBlock", status: procStatus)
            }
            chain.procID = procID

            // 4. Rebuild when the tap format or the aggregate's sample rate changes.
            chain.listeners.append(try CoreAudioSupport.addListener(
                to: tapID, kAudioTapPropertyFormat, queue: controlQueue
            ) { [weak self] in
                self?.sampleRateMayHaveChanged()
            })
            chain.listeners.append(try CoreAudioSupport.addListener(
                to: aggregateID, kAudioDevicePropertyNominalSampleRate, queue: controlQueue
            ) { [weak self] in
                self?.sampleRateMayHaveChanged()
            })

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                throw CaptureError.coreAudio(operation: "AudioDeviceStart", status: startStatus)
            }
            chain.isStarted = true
            return chain
        } catch {
            destroy(chain)
            throw error
        }
    }

    /// Tears a (possibly partial) chain down in reverse order, then drains the IO queue so
    /// no callback of the old chain can run afterwards.
    private func destroy(_ chain: CaptureChain, drainingIO: Bool = true) {
        chain.listeners.forEach { $0.remove() }
        if let procID = chain.procID {
            if chain.isStarted {
                logIfFailed(AudioDeviceStop(chain.aggregateID, procID), "AudioDeviceStop")
            }
            logIfFailed(AudioDeviceDestroyIOProcID(chain.aggregateID, procID), "AudioDeviceDestroyIOProcID")
        }
        if chain.aggregateID != kAudioObjectUnknown {
            logIfFailed(AudioHardwareDestroyAggregateDevice(chain.aggregateID), "AudioHardwareDestroyAggregateDevice")
        }
        if chain.tapID != kAudioObjectUnknown {
            logIfFailed(AudioHardwareDestroyProcessTap(chain.tapID), "AudioHardwareDestroyProcessTap")
        }
        if drainingIO {
            ioQueue.sync {}
        }
    }

    private func sampleRateMayHaveChanged() {
        guard state == .running, let chain else { return }
        let tapRate = (try? CoreAudioSupport.value(
            of: chain.tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()
        ))?.mSampleRate
        let aggregateRate = try? CoreAudioSupport.value(
            of: chain.aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)
        )
        // Creating the chain itself can fire these notifications; only react to a real change.
        let changed = [tapRate, aggregateRate].contains { rate in
            guard let rate, rate > 0 else { return false }
            return abs(rate - chain.sampleRate) > 0.5
        }
        if changed {
            scheduleRebuild()
        }
    }

    /// Coalesces bursts of device notifications into one rebuild.
    private func scheduleRebuild(after delay: TimeInterval = rebuildDebounce) {
        guard state == .running, !rebuildScheduled else { return }
        rebuildScheduled = true
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.rebuild()
        }
    }

    private func rebuild() {
        rebuildScheduled = false
        guard state == .running else { return }
        if let chain { destroy(chain) }
        chain = nil
        writerLock.withLock { writer?.resetConverter() }
        do {
            chain = try buildChain()
            rebuildAttempts = 0
            logger.info("System audio capture rebuilt after a device change")
        } catch {
            rebuildAttempts += 1
            logger.error("System audio rebuild failed (attempt \(self.rebuildAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            if rebuildAttempts < Self.maxRebuildAttempts {
                scheduleRebuild(after: Self.rebuildRetryDelay)
            }
        }
    }

    // MARK: - IO (ioQueue)

    private func handleInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        time: UnsafePointer<AudioTimeStamp>,
        format: AVAudioFormat
    ) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0
        else { return }
        let timestamp = time.pointee
        let hostTime: UInt64
        if timestamp.mFlags.contains(.hostTimeValid) {
            hostTime = timestamp.mHostTime
        } else {
            let duration = Double(buffer.frameLength) / format.sampleRate
            hostTime = HostTime.now() &- HostTime.ticks(fromSeconds: duration)
        }
        writerLock.withLock {
            writer?.append(buffer, hostTime: hostTime)
        }
    }

    private func logIfFailed(_ status: OSStatus, _ operation: String) {
        guard status != noErr else { return }
        logger.error("\(operation, privacy: .public) failed with status \(status, privacy: .public)")
    }
}
