import AVFoundation
import Testing
@testable import MinutesCapture

@Suite struct AlignedPCMFileWriterTests {
    /// The MacBook microphone array arrives as 3 unlabeled channels while a call uses it
    /// (meeting of 2026-10-20 12:54); AVAudioConverter's downmix turned it into pure silence.
    @Test func unlabeledMultichannelInputIsMixedInsteadOfSilenced() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        #expect(try peakWritten(tone: format) > 10_000)
    }

    @Test func stereoInputStillComesOutAtTheSameLevel() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        #expect(try peakWritten(tone: format) > 10_000)
    }

    @Test func monoInputIsWrittenAsIs() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        #expect(try peakWritten(tone: format) > 10_000)
    }

    /// Writes one second of a 0.5-amplitude tone on every channel and returns the file's peak sample.
    private func peakWritten(tone format: AVAudioFormat) throws -> Int16 {
        let url = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let reference = HostTime.now()
        let writer = try AlignedPCMFileWriter(url: url, referenceHostTime: reference, logCategory: "Tests")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<48_000 { channels[channel][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000) }
        }
        writer.append(buffer, hostTime: reference)
        writer.finish(endHostTime: reference &+ HostTime.ticks(fromSeconds: 1))

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let written = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: written)
        let samples = try #require(written.int16ChannelData?[0])
        return (0..<Int(written.frameLength)).reduce(0) { max($0, abs(samples[$1])) }
    }
}
