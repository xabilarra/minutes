import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

public struct VideoRecordingResult: Sendable {
    /// Final file: the requested `.mp4`, or a `.mov` next to it when the remux failed.
    public let outputURL: URL
    /// Host time (`mach_absolute_time` ticks) of the first written frame, i.e. video time 0.
    public let firstFrameHostTime: UInt64?
    /// Seconds of video written.
    public let duration: Double

    public init(outputURL: URL, firstFrameHostTime: UInt64?, duration: Double) {
        self.outputURL = outputURL
        self.firstFrameHostTime = firstFrameHostTime
        self.duration = duration
    }
}

/// Records one window with ScreenCaptureKit and `AVAssetWriter` (HEVC, hardware encoder).
///
/// Frames are written to `<output without extension>.partial.mov` with 10 s movie fragments,
/// so a crash still leaves a playable file. On stop (or interruption) the movie is finalized
/// and remuxed without re-encoding to the requested `.mp4`.
///
/// Timeline: the writer session starts at the first frame, whose host time (ScreenCaptureKit's
/// `displayTime`, i.e. `mach_absolute_time`) is reported as `firstFrameHostTime`. The session
/// ends at the stop time (last frame + host time elapsed since it), so a window that stays
/// static at the end of the call does not shorten the video.
public final class WindowVideoRecorder: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var framesPerSecond: Int
        /// Maximum long edge in pixels; larger windows are scaled down keeping the aspect ratio.
        public var maxLongEdge: Int

        public init(framesPerSecond: Int = 15, maxLongEdge: Int = 2560) {
            self.framesPerSecond = framesPerSecond
            self.maxLongEdge = maxLongEdge
        }
    }

    private let outputURL: URL
    private let partialURL: URL
    private let fallbackURL: URL
    private let options: Options
    private let sampleQueue = DispatchQueue(label: "io.github.xabilarra.Minutes.video.samples", qos: .userInitiated)
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "WindowVideo")

    // Guarded by `lock`.
    private let lock = NSLock()
    private var interruptionHandler: (@Sendable (Error) -> Void)?
    private var hasStarted = false
    private var finalization: Task<VideoRecordingResult, Error>?

    // Owned by `sampleQueue`.
    private var windowID: UInt32 = 0
    /// Meeting window when following the focus; nil for a fixed window or display.
    private var anchorWindowID: UInt32?
    private var isReturningToAnchor = false
    /// True when following the display the user is looking at.
    private var followsDisplay = false
    private var recordedDisplayID: UInt32?
    private var stream: SCStream?
    private var sink: StreamSink?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var acceptingFrames = false
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var firstFrameHostTime: UInt64?
    private var lastFrameHostTime: UInt64?

    public init(outputURL: URL, options: Options = Options()) {
        self.outputURL = outputURL
        self.options = options
        let base = outputURL.deletingPathExtension()
        partialURL = base.appendingPathExtension("partial").appendingPathExtension("mov")
        fallbackURL = base.appendingPathExtension("mov")
    }

    deinit {
        stream?.stopCapture(completionHandler: nil)
    }

    /// Called once, on an arbitrary queue, if capture stops by itself (window closed, stream
    /// or writer error). The file is already finalized when it is called.
    public var onInterrupted: (@Sendable (Error) -> Void)? {
        get { lock.withLock { interruptionHandler } }
        set { lock.withLock { interruptionHandler = newValue } }
    }

    /// Starts recording the window. Throws `windowNotFound` when it is not shareable and
    /// `permissionDenied` when Screen Recording access is missing. Can only be called once.
    public func start(windowID: UInt32) async throws {
        try markStarted()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await begin(filter: filter, frame: window.frame, sourceWindowID: windowID)
    }

    /// Starts recording the whole display that shows `windowID` (the main display when it is nil
    /// or not found), so content the user presents from other windows is recorded too. This app's
    /// own windows, such as the recording indicator, are left out. Can only be called once.
    public func start(displayContainingWindowID windowID: UInt32?) async throws {
        try markStarted()
        let content = try await shareableContent()
        let window = windowID.flatMap { id in content.windows.first { $0.windowID == id } }
        let display = window.flatMap { window in
            content.displays.first { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
        } ?? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        guard let display else {
            throw CaptureError.unsupported("no display is available to record")
        }
        sampleQueue.sync { recordedDisplayID = display.displayID }
        try await begin(filter: Self.displayFilter(display, content: content), frame: display.frame, sourceWindowID: windowID ?? 0)
    }

    /// Display a display recording started on; nil for window recordings.
    public var displayID: UInt32? {
        sampleQueue.sync { recordedDisplayID }
    }

    /// Like `start(displayContainingWindowID:)`, but `follow(displayID:)` can later switch to the
    /// display the user is looking at without restarting the file; each display is scaled to fit
    /// the first one's frame. Closing windows never stops it. Can only be called once.
    public func start(followingDisplayFrom windowID: UInt32?) async throws {
        sampleQueue.sync { followsDisplay = true }
        try await start(displayContainingWindowID: windowID)
    }

    /// Switches a recording started with `start(followingDisplayFrom:)` to `displayID`. Does nothing
    /// for other recordings or once capture has stopped; throws when the display is not available.
    public func follow(displayID: UInt32) async throws {
        let followedStream = sampleQueue.sync { followsDisplay && acceptingFrames ? self.stream : nil }
        guard let stream = followedStream else { return }
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.unsupported("display \(displayID) is not available to record")
        }
        do {
            try await stream.updateContentFilter(Self.displayFilter(display, content: content))
        } catch {
            throw ScreenCaptureErrors.map(error)
        }
    }

    /// The whole display, leaving out this app's own windows such as the recording indicator.
    private static func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    /// Starts recording `windowID` in a frame sized for the display that shows it, so
    /// `follow(windowID:)` can later switch to the window the user focuses without restarting the
    /// file; each window is scaled to fit that frame. When a followed window closes, recording
    /// returns to `windowID`. Can only be called once.
    public func start(followingFocusFrom windowID: UInt32) async throws {
        try markStarted()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let display = content.displays.first { $0.frame.contains(center) }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        sampleQueue.sync { anchorWindowID = windowID }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await begin(filter: filter, frame: display?.frame ?? window.frame, sourceWindowID: windowID)
    }

    /// Switches a recording started with `start(followingFocusFrom:)` to `windowID`. Does nothing
    /// for other recordings or once capture has stopped; throws `windowNotFound` when the window
    /// is not shareable.
    public func follow(windowID: UInt32) async throws {
        let followedStream = sampleQueue.sync { anchorWindowID != nil && acceptingFrames ? self.stream : nil }
        guard let stream = followedStream else { return }
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        do {
            try await stream.updateContentFilter(SCContentFilter(desktopIndependentWindow: window))
        } catch {
            throw ScreenCaptureErrors.map(error)
        }
        sampleQueue.sync { self.windowID = windowID }
    }

    private func markStarted() throws {
        try lock.withLock {
            guard !hasStarted else {
                throw CaptureError.unsupported("window video recorder can only be started once")
            }
            hasStarted = true
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw ScreenCaptureErrors.map(error)
        }
    }

    private func begin(filter: SCContentFilter, frame: CGRect, sourceWindowID windowID: UInt32) async throws {
        let scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        let size = Self.pixelSize(
            width: Double(frame.width),
            height: Double(frame.height),
            scale: scale,
            maxLongEdge: options.maxLongEdge
        )
        let fps = max(1, options.framesPerSecond)
        let configuration = Self.streamConfiguration(width: size.width, height: size.height, fps: fps)

        let (writer, input, adaptor) = try makeWriter(width: size.width, height: size.height, fps: fps)
        let sink = StreamSink(recorder: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            discardWriter(writer)
            throw CaptureError.writer("could not attach to the capture stream (\((error as NSError).code))")
        }

        sampleQueue.sync {
            self.windowID = windowID
            self.stream = stream
            self.sink = sink
            self.writer = writer
            self.writerInput = input
            self.pixelAdaptor = adaptor
            self.acceptingFrames = true
        }

        do {
            try await stream.startCapture()
        } catch {
            sampleQueue.sync {
                self.acceptingFrames = false
                self.stream = nil
                self.sink = nil
                self.writer = nil
                self.writerInput = nil
                self.pixelAdaptor = nil
            }
            discardWriter(writer)
            throw ScreenCaptureErrors.map(error)
        }

        // `stop()` may have raced with startup; make sure capture does not keep running.
        if lock.withLock({ finalization != nil }) {
            try? await stream.stopCapture()
        }
    }

    /// Stops capture, finalizes and remuxes to the requested URL. Safe after an interruption
    /// (returns the already finalized result). Throws only if nothing usable was written.
    public func stop() async throws -> VideoRecordingResult {
        try await beginFinalization(stoppingStream: true).task.value
    }

    // MARK: - Configuration

    /// Window size in pixels, scaled so the long edge fits `maxLongEdge`, with even dimensions.
    static func pixelSize(width: Double, height: Double, scale: Double, maxLongEdge: Int) -> (width: Int, height: Int) {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        var pixelWidth = max(1, width * safeScale)
        var pixelHeight = max(1, height * safeScale)
        let limit = Double(max(2, maxLongEdge))
        let longEdge = max(pixelWidth, pixelHeight)
        if longEdge > limit {
            pixelWidth *= limit / longEdge
            pixelHeight *= limit / longEdge
        }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        return (even(pixelWidth), even(pixelHeight))
    }

    /// Average bit rate: 0.035 bits per pixel per frame, clamped to 1.5–6 Mbit/s.
    static func averageBitRate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width) * Double(height) * Double(fps) * 0.035
        return Int(min(6_000_000, max(1_500_000, raw)))
    }

    private static func streamConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // '420v'
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 5
        // Keep the whole window visible if it is resized during the call.
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    private func makeWriter(
        width: Int,
        height: Int,
        fps: Int
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        try? FileManager.default.removeItem(at: partialURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partialURL, fileType: .mov)
        } catch {
            throw CaptureError.writer("could not create the video file (\((error as NSError).code))")
        }
        // Fragments make the partial file playable even if the app dies mid-recording.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        // VideoToolbox picks the hardware HEVC encoder by default on Apple silicon.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.averageBitRate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CaptureError.unsupported("HEVC encoding at \(width)x\(height) is not available")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.writer("could not add the video track")
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else {
            let code = (writer.error as NSError?)?.code ?? 0
            discardWriter(writer)
            throw CaptureError.writer("could not start the video writer (\(code))")
        }
        return (writer, input, adaptor)
    }

    private func discardWriter(_ writer: AVAssetWriter) {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: partialURL)
    }

    // MARK: - Samples (sampleQueue)

    fileprivate func handle(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, acceptingFrames,
              let writer, let writerInput, let pixelAdaptor,
              sampleBuffer.isValid,
              let status = Self.frameStatus(of: sampleBuffer)
        else { return }

        if status == .stopped {
            if let anchorWindowID, windowID != anchorWindowID {
                returnToAnchor(anchorWindowID)
            } else {
                interrupt(with: CaptureError.windowNotFound(windowID), stoppingStream: false)
            }
            return
        }
        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid, lastPTS.map({ pts > $0 }) ?? true else { return }
        // Real-time input: when the encoder is busy, drop this frame rather than block capture.
        guard writerInput.isReadyForMoreMediaData else { return }

        let hostTime = Self.displayHostTime(of: sampleBuffer) ?? CMClockConvertHostTimeToSystemUnits(pts)
        if firstPTS == nil {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            firstFrameHostTime = hostTime
        }
        if pixelAdaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastPTS = pts
            lastFrameHostTime = hostTime
        } else {
            let code = (writer.error as NSError?)?.code ?? 0
            interrupt(with: CaptureError.writer("video encoding failed (\(code))"), stoppingStream: true)
        }
    }

    private static func frameInfo(of sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
    }

    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let rawStatus = frameInfo(of: sampleBuffer)?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: rawStatus)
    }

    /// `mach_absolute_time` at which the frame was displayed, when ScreenCaptureKit provides it.
    private static func displayHostTime(of sampleBuffer: CMSampleBuffer) -> UInt64? {
        (frameInfo(of: sampleBuffer)?[.displayTime] as? NSNumber)?.uint64Value
    }

    /// Called on `sampleQueue` when a followed window closed: records the meeting window again.
    private func returnToAnchor(_ anchor: UInt32) {
        guard !isReturningToAnchor else { return }
        isReturningToAnchor = true
        let closedWindowID = windowID
        Task {
            do {
                try await self.follow(windowID: anchor)
            } catch {
                self.logger.error("Could not return to the meeting window: \(error.localizedDescription, privacy: .public)")
            }
            self.sampleQueue.async {
                self.isReturningToAnchor = false
                if self.windowID == closedWindowID {
                    self.interrupt(with: CaptureError.windowNotFound(closedWindowID), stoppingStream: true)
                }
            }
        }
    }

    /// Called on `sampleQueue` when the recording cannot continue.
    private func interrupt(with error: Error, stoppingStream: Bool) {
        acceptingFrames = false
        notifyAfterFinalization(error, stoppingStream: stoppingStream)
    }

    fileprivate func streamDidStop(with error: Error) {
        notifyAfterFinalization(ScreenCaptureErrors.map(error), stoppingStream: false)
    }

    /// Finalizes, then calls `onInterrupted` once, unless a stop was already in progress.
    private func notifyAfterFinalization(_ error: Error, stoppingStream: Bool) {
        let (task, isNew) = beginFinalization(stoppingStream: stoppingStream)
        guard isNew else { return }
        logger.error("Window capture interrupted: \(error.localizedDescription, privacy: .public)")
        Task {
            _ = try? await task.value
            self.onInterrupted?(error)
        }
    }

    // MARK: - Finalization

    /// Returns the single finalization task, creating it on first use.
    private func beginFinalization(stoppingStream: Bool) -> (task: Task<VideoRecordingResult, Error>, isNew: Bool) {
        lock.withLock {
            if let finalization {
                return (finalization, false)
            }
            let task = Task { try await self.finalize(stoppingStream: stoppingStream) }
            finalization = task
            return (task, true)
        }
    }

    /// Writer state captured once capture has stopped.
    private struct FinalState {
        let writer: AVAssetWriter?
        let input: AVAssetWriterInput?
        let firstPTS: CMTime?
        let lastPTS: CMTime?
        let firstFrameHostTime: UInt64?
        let lastFrameHostTime: UInt64?
    }

    private func finalize(stoppingStream: Bool) async throws -> VideoRecordingResult {
        let stopHostTime = HostTime.now()
        let stream = sampleQueue.sync { () -> SCStream? in
            acceptingFrames = false
            return self.stream
        }
        if stoppingStream, let stream {
            try? await stream.stopCapture()
        }

        // Every frame callback has been delivered on sampleQueue by now; take the final state.
        let final = sampleQueue.sync { () -> FinalState in
            // Explicit `self.`: locals of the same names are declared later in this function.
            let snapshot = FinalState(
                writer: self.writer,
                input: self.writerInput,
                firstPTS: self.firstPTS,
                lastPTS: self.lastPTS,
                firstFrameHostTime: self.firstFrameHostTime,
                lastFrameHostTime: self.lastFrameHostTime
            )
            self.stream = nil
            self.sink = nil
            self.writer = nil
            self.writerInput = nil
            self.pixelAdaptor = nil
            return snapshot
        }
        guard let writer = final.writer, let input = final.input else {
            throw CaptureError.writer("no video was recorded")
        }
        guard let firstPTS = final.firstPTS, let lastPTS = final.lastPTS else {
            discardWriter(writer)
            throw CaptureError.writer("no video frames were captured")
        }

        // Hold the last frame until the stop time; elapsed host time keeps this independent of
        // the clock the presentation times are expressed in.
        let heldSeconds = final.lastFrameHostTime.map { max(0, HostTime.seconds(from: $0, to: stopHostTime)) } ?? 0
        let endPTS = CMTimeAdd(lastPTS, CMTime(seconds: heldSeconds, preferredTimescale: 1_000_000))
        if writer.status == .writing {
            input.markAsFinished()
            writer.endSession(atSourceTime: endPTS)
            await writer.finishWriting()
        }
        if writer.status != .completed {
            logger.error("Video writer did not complete (status \(writer.status.rawValue, privacy: .public)); keeping written fragments")
        }

        let duration = max(0, CMTimeGetSeconds(CMTimeSubtract(endPTS, firstPTS)))
        let firstFrameHostTime = final.firstFrameHostTime ?? CMClockConvertHostTimeToSystemUnits(firstPTS)
        let finalURL = try await remuxOrKeepMovie()
        return VideoRecordingResult(outputURL: finalURL, firstFrameHostTime: firstFrameHostTime, duration: duration)
    }

    /// Remuxes the partial `.mov` into the requested `.mp4` without re-encoding. When that
    /// fails, the movie is kept as `<output>.mov` (or at its partial path if it cannot be moved).
    private func remuxOrKeepMovie() async throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw CaptureError.writer("the video file is missing")
        }
        try? fileManager.removeItem(at: outputURL)
        do {
            guard let session = AVAssetExportSession(
                asset: AVURLAsset(url: partialURL),
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw CaptureError.unsupported("passthrough export is not available for this movie")
            }
            session.shouldOptimizeForNetworkUse = true
            try await session.export(to: outputURL, as: .mp4)
            try? fileManager.removeItem(at: partialURL)
            return outputURL
        } catch {
            logger.error("Video remux failed, keeping the .mov: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: outputURL)
            guard fallbackURL != outputURL else { return partialURL }
            try? fileManager.removeItem(at: fallbackURL)
            do {
                try fileManager.moveItem(at: partialURL, to: fallbackURL)
                return fallbackURL
            } catch {
                return partialURL
            }
        }
    }
}

/// Bridges ScreenCaptureKit's Objective-C protocols without exposing NSObject on the public type.
private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var recorder: WindowVideoRecorder?

    init(recorder: WindowVideoRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        recorder?.handle(sampleBuffer, type: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recorder?.streamDidStop(with: error)
    }
}
