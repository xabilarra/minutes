import Accelerate
import AVFAudio
import Foundation

/// Offline helpers over recorded audio files (any format `AVAudioFile` can read).
public enum AudioFileTools {
    /// Level reported for digital silence or an empty range.
    static let silenceDB = -160.0
    private static let readChunkFrames: AVAudioFrameCount = 32_768

    /// Duration of the file in seconds.
    public static func duration(of url: URL) throws -> Double {
        let file = try openForReading(url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    /// Encodes `[start, start + duration)` (the whole file when `duration` is nil) as AAC
    /// `.m4a`, mono, 16 kHz, 32 kbps. Overwrites `destination`; removes it again on failure.
    public static func exportM4A(from source: URL, to destination: URL, start: Double = 0, duration: Double? = nil) throws {
        try exportM4A(from: source, to: destination, ranges: [(start, duration)])
    }

    /// Like `exportM4A(from:to:start:duration:)`, with the ranges played back to back in one file.
    public static func exportM4A(
        from source: URL, to destination: URL, ranges: [(start: Double, duration: Double?)]
    ) throws {
        let input = try openForReading(source)
        let frameRanges = ranges.map { frameRange(of: input, start: $0.start, duration: $0.duration) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]

        try? FileManager.default.removeItem(at: destination)
        do {
            let output: AVAudioFile
            do {
                output = try AVAudioFile(
                    forWriting: destination,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw CaptureError.writer("could not create the AAC file (\((error as NSError).code))")
            }
            defer { output.close() }

            let outputFormat = output.processingFormat
            var converter: AVAudioConverter?
            if input.processingFormat != outputFormat {
                guard let created = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
                    throw CaptureError.unsupported("cannot convert this audio file to 16 kHz mono")
                }
                created.downmix = input.processingFormat.channelCount > 1
                converter = created
            }
            let write: (AVAudioPCMBuffer) throws -> Void = { buffer in
                do {
                    try output.write(from: buffer)
                } catch {
                    throw CaptureError.writer("could not encode audio (\((error as NSError).code))")
                }
            }

            for range in frameRanges {
                try forEachChunk(of: input, in: range, maxFrames: readChunkFrames) { chunk in
                    if let converter {
                        try ConverterPump.convert(converter, input: chunk, outputFormat: outputFormat, emit: write)
                    } else {
                        try write(chunk)
                    }
                }
            }
            if let converter {
                try ConverterPump.convert(converter, input: nil, outputFormat: outputFormat, emit: write)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Loudest RMS level in dBFS over consecutive 0.5 s windows of `[start, start + duration)`,
    /// or -160 for digital silence or an empty range. Used to skip silent chunks.
    public static func peakWindowLevelDB(of url: URL, start: Double, duration: Double) throws -> Double {
        let file = try openForReading(url)
        let range = frameRange(of: file, start: start, duration: duration)
        var peak = silenceDB
        try forEachChunk(of: file, in: range, maxFrames: halfSecondFrames(of: file)) { window in
            peak = max(peak, levelDB(of: window))
        }
        return peak
    }

    /// RMS level in dBFS of each consecutive 0.5 s window of the whole file (the last one may be
    /// shorter), -160 for digital silence. Used to find the speech worth uploading.
    public static func windowLevelsDB(of url: URL) throws -> [Double] {
        let file = try openForReading(url)
        var levels: [Double] = []
        try forEachChunk(of: file, in: 0..<file.length, maxFrames: halfSecondFrames(of: file)) { window in
            levels.append(levelDB(of: window))
        }
        return levels
    }

    /// Length in seconds of the windows `windowLevelsDB` measures.
    public static let levelWindowDuration = 0.5

    // MARK: - Private

    private static func halfSecondFrames(of file: AVAudioFile) -> AVAudioFrameCount {
        AVAudioFrameCount(max(1, (file.processingFormat.sampleRate * levelWindowDuration).rounded()))
    }

    private static func levelDB(of window: AVAudioPCMBuffer) -> Double {
        guard let channels = window.floatChannelData, window.frameLength > 0 else { return silenceDB }
        let channelCount = Int(window.format.channelCount)
        var sumOfMeanSquares = 0.0
        for channel in 0..<channelCount {
            var meanSquare: Float = 0
            vDSP_measqv(channels[channel], 1, &meanSquare, vDSP_Length(window.frameLength))
            sumOfMeanSquares += Double(meanSquare)
        }
        let rms = (sumOfMeanSquares / Double(max(1, channelCount))).squareRoot()
        return rms > 0 ? max(silenceDB, 20 * log10(rms)) : silenceDB
    }

    private static func openForReading(_ url: URL) throws -> AVAudioFile {
        do {
            // Default processing format: Float32, deinterleaved, at the file's sample rate.
            return try AVAudioFile(forReading: url)
        } catch {
            throw CaptureError.writer("could not open the audio file (\((error as NSError).code))")
        }
    }

    /// Clamps a time range in seconds to the file's frames.
    private static func frameRange(of file: AVAudioFile, start: Double, duration: Double?) -> Range<AVAudioFramePosition> {
        let sampleRate = file.processingFormat.sampleRate
        let length = file.length
        func frames(_ seconds: Double) -> AVAudioFramePosition {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return AVAudioFramePosition((seconds * sampleRate).rounded())
        }
        let lower = min(length, frames(start))
        let upper = duration.map { min(length, lower + frames($0)) } ?? length
        return lower..<max(lower, upper)
    }

    /// Reads `range` sequentially in chunks of at most `maxFrames`, reusing one buffer.
    private static func forEachChunk(
        of file: AVAudioFile,
        in range: Range<AVAudioFramePosition>,
        maxFrames: AVAudioFrameCount,
        body: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        guard !range.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: maxFrames) else {
            throw CaptureError.writer("could not allocate a read buffer")
        }
        file.framePosition = range.lowerBound
        var remaining = range.count
        while remaining > 0 {
            let request = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), AVAudioFramePosition(remaining)))
            do {
                try file.read(into: buffer, frameCount: request)
            } catch {
                throw CaptureError.writer("could not read audio (\((error as NSError).code))")
            }
            guard buffer.frameLength > 0 else { return }
            remaining -= Int(buffer.frameLength)
            try body(buffer)
        }
    }
}
