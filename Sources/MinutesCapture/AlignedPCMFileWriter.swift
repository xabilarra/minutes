import AVFAudio
import Foundation
import os

/// Drives an `AVAudioConverter` for one input buffer (or an end-of-stream drain) and hands
/// every produced output buffer to `emit`.
///
/// The input is fed in owned copies of at most `maxSliceFrames` frames. Measured on macOS 26:
/// given a larger buffer, the converter consumes only ~4096 frames per pull and keeps the
/// remainder for a later burst, which delays output by up to ~90 ms and can reference memory
/// that is only valid during an IO callback. With small owned slices every pull is consumed
/// completely and the remaining latency is the resampler's own (~5 output frames).
enum ConverterPump {
    static let maxSliceFrames: AVAudioFrameCount = 1_024

    static func convert(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer?,
        outputFormat: AVAudioFormat,
        emit: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let inputFrames = Double(input?.frameLength ?? 0)
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        // Room for the resampled input plus whatever the converter still holds internally.
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 1_024
        let feed = InputFeed(buffer: input)

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw CaptureError.writer("could not allocate a conversion buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                feed.next(inputStatus)
            }
            if status == .error {
                throw CaptureError.writer("audio conversion failed (\(conversionError?.code ?? 0))")
            }
            if output.frameLength > 0 {
                try emit(output)
            }
            // `.haveData` means the output buffer was filled and more may be pending.
            guard status == .haveData else { return }
        }
    }

    /// Supplies the input buffer as consecutive owned slices; afterwards reports "no data now"
    /// (streaming) or "end of stream" (drain, when no buffer was given).
    ///
    /// `@unchecked Sendable`: the converter's input block is typed `@Sendable` but is only
    /// invoked synchronously inside `convert(to:error:withInputFrom:)` on the calling thread.
    private final class InputFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer?
        private var offset: AVAudioFrameCount = 0

        init(buffer: AVAudioPCMBuffer?) {
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .endOfStream
                return nil
            }
            guard offset < buffer.frameLength,
                  let slice = Self.copy(buffer, from: offset, count: min(maxSliceFrames, buffer.frameLength - offset))
            else {
                status.pointee = .noDataNow
                return nil
            }
            offset += slice.frameLength
            status.pointee = .haveData
            return slice
        }

        /// Copies `count` frames starting at `start` into a new buffer of the same PCM format.
        private static func copy(_ source: AVAudioPCMBuffer, from start: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
            guard count > 0,
                  let slice = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count)
            else { return nil }
            // For interleaved formats there is one buffer holding every channel; for
            // deinterleaved formats one buffer per channel. mBytesPerFrame matches either layout.
            let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
            let sliceBuffers = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            guard bytesPerFrame > 0, sourceBuffers.count == sliceBuffers.count else { return nil }
            for index in 0..<sourceBuffers.count {
                guard let from = sourceBuffers[index].mData, let to = sliceBuffers[index].mData else { return nil }
                to.copyMemory(from: from + Int(start) * bytesPerFrame, byteCount: Int(count) * bytesPerFrame)
                sliceBuffers[index].mDataByteSize = UInt32(Int(count) * bytesPerFrame)
            }
            slice.frameLength = count
            return slice
        }
    }
}

/// Writes a 16 kHz mono Int16 CAF whose timeline is anchored to a host time.
///
/// File time 0 is `referenceHostTime`. Every appended buffer carries the host time of its
/// first sample; when the file is behind that position by more than `maxDriftSeconds`
/// (or at all, before the first write) zero frames are inserted. Audio is never dropped,
/// except samples that precede the reference itself (they have no place on the timeline).
///
/// Not thread-safe: the owner serializes all calls.
final class AlignedPCMFileWriter {
    static let sampleRate: Double = 16_000
    /// Tolerated lag before silence is inserted (resampler latency and timestamp jitter stay below it).
    static let maxDriftSeconds = 0.05
    /// Larger gaps are treated as bogus timestamps rather than real silence (12 hours).
    private static let maxPlausibleGapFrames = AVAudioFramePosition(12 * 3_600 * sampleRate)

    let referenceHostTime: UInt64
    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var hasWritten = false
    private var isClosed = false
    private var reportedWriteError = false
    private let silence: AVAudioPCMBuffer
    private let logger: Logger

    /// Creates (or truncates) the file at `url`. The extension should be `.caf`.
    init(url: URL, referenceHostTime: UInt64, logCategory: String) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.writer("could not create the 16 kHz Int16 format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw CaptureError.writer("could not create the audio file (\((error as NSError).code))")
        }
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.sampleRate / 2)) else {
            throw CaptureError.writer("could not allocate the silence buffer")
        }
        silence.frameLength = silence.frameCapacity
        if let samples = silence.int16ChannelData?[0] {
            samples.update(repeating: 0, count: Int(silence.frameCapacity))
        }
        self.silence = silence
        outputFormat = format
        self.referenceHostTime = referenceHostTime
        logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: logCategory)
    }

    /// Converts `buffer` (any PCM format) and appends it at the position implied by `hostTime`.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard !isClosed, buffer.frameLength > 0 else { return }
        do {
            let buffer = Self.mixedToMonoIfUnlabeled(buffer)
            let converter = try converter(for: buffer.format)
            let startSeconds = HostTime.seconds(from: referenceHostTime, to: hostTime)
            var expectedFrame = AVAudioFramePosition((startSeconds * Self.sampleRate).rounded())
            try ConverterPump.convert(converter, input: buffer, outputFormat: outputFormat) { output in
                try write(output, expectedStartFrame: expectedFrame)
                expectedFrame += AVAudioFramePosition(output.frameLength)
            }
        } catch {
            reportOnce(error)
        }
    }

    /// Flushes and forgets the resampler, for example after the source device changed, so
    /// the next buffer starts a fresh converter for whatever format it has.
    func resetConverter() {
        guard !isClosed else { return }
        do {
            try drainConverter()
        } catch {
            reportOnce(error)
        }
    }

    /// Flushes the converter, pads the tail up to `endHostTime` and closes the file. Idempotent.
    func finish(endHostTime: UInt64) {
        guard !isClosed else { return }
        do {
            try drainConverter()
            let endFrame = AVAudioFramePosition(
                (HostTime.seconds(from: referenceHostTime, to: endHostTime) * Self.sampleRate).rounded()
            )
            try padIfBehind(expectedFrame: endFrame, strict: !hasWritten)
        } catch {
            reportOnce(error)
        }
        isClosed = true
        file.close()
    }

    // MARK: - Private

    /// AVAudioConverter only downmixes channels it can name: unlabeled ones (the MacBook's
    /// 3-microphone array while a call uses it) come out as pure silence, so they are averaged
    /// here instead. Labeled layouts such as stereo keep going through the converter.
    private static func mixedToMonoIfUnlabeled(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        guard format.channelCount > 1, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return buffer }
        let tag = format.channelLayout?.layoutTag
        let unlabeled = tag.map {
            $0 & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder || $0 == kAudioChannelLayoutTag_UseChannelDescriptions
        } ?? (format.channelCount > 2)
        guard unlabeled,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0] else { return buffer }
        mono.frameLength = buffer.frameLength
        let count = Int(format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<count { sum += channels[channel][frame] }
            output[frame] = sum / Float(count)
        }
        return mono
    }

    private func converter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converter.inputFormat == inputFormat {
            return converter
        }
        // Keep the old converter's last few frames: they belong before the new format's audio.
        try drainConverter()
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.unsupported(
                "cannot convert \(inputFormat.channelCount) ch @ \(inputFormat.sampleRate) Hz to 16 kHz mono"
            )
        }
        // Mix every input channel into the single output channel instead of keeping only the first.
        converter.downmix = inputFormat.channelCount > 1
        self.converter = converter
        return converter
    }

    /// Writes whatever the current converter still holds (contiguously) and discards it.
    private func drainConverter() throws {
        guard let converter else { return }
        self.converter = nil
        try ConverterPump.convert(converter, input: nil, outputFormat: outputFormat) { output in
            try writeFrames(output, from: 0)
        }
    }

    private func write(_ output: AVAudioPCMBuffer, expectedStartFrame: AVAudioFramePosition) throws {
        let length = AVAudioFramePosition(output.frameLength)
        // Samples before the reference host time have no place on the file timeline.
        let skip = min(length, max(0, -expectedStartFrame))
        guard skip < length else { return }
        try padIfBehind(expectedFrame: expectedStartFrame + skip, strict: !hasWritten)
        try writeFrames(output, from: AVAudioFrameCount(skip))
    }

    /// Inserts silence when the file lags `expectedFrame`; `strict` pads any lag (leading silence).
    private func padIfBehind(expectedFrame: AVAudioFramePosition, strict: Bool) throws {
        let gap = expectedFrame - framesWritten
        let threshold = strict ? 0 : AVAudioFramePosition(Self.maxDriftSeconds * Self.sampleRate)
        guard gap > threshold else { return }
        guard gap <= Self.maxPlausibleGapFrames else {
            logger.error("Ignoring implausible audio gap of \(gap, privacy: .public) frames")
            return
        }
        var remaining = gap
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(remaining, AVAudioFramePosition(silence.frameCapacity)))
            silence.frameLength = chunk
            try writeToFile(silence)
            remaining -= AVAudioFramePosition(chunk)
        }
        silence.frameLength = silence.frameCapacity
    }

    private func writeFrames(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) throws {
        guard offset > 0 else {
            try writeToFile(buffer)
            return
        }
        let count = buffer.frameLength - offset
        guard count > 0,
              let slice = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count),
              let source = buffer.int16ChannelData?[0],
              let destination = slice.int16ChannelData?[0]
        else { return }
        destination.update(from: source.advanced(by: Int(offset)), count: Int(count))
        slice.frameLength = count
        try writeToFile(slice)
    }

    private func writeToFile(_ buffer: AVAudioPCMBuffer) throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw CaptureError.writer("could not write audio (\((error as NSError).code))")
        }
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        hasWritten = true
    }

    private func reportOnce(_ error: Error) {
        guard !reportedWriteError else { return }
        reportedWriteError = true
        logger.error("Audio track write failed: \(error.localizedDescription, privacy: .public)")
    }
}
