import AVFoundation
import Foundation
import MinutesCapture
import Testing

@Suite struct AudioFileToolsTests {
    /// Chunks of real meetings join several pieces of speech: the upload must hold exactly those
    /// pieces, back to back, and none of the silence between them.
    @Test func exportsSeveralRangesBackToBackInOneFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinutesAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "track.caf")
        // Tone 0-3 s, silence 3-7 s, tone 7-10 s.
        try writeTrack(to: source, seconds: 10) { time in time < 3 || time >= 7 }
        let output = directory.appending(path: "upload.m4a")

        try AudioFileTools.exportM4A(from: source, to: output, ranges: [(0.5, 2), (7.5, 2)])

        #expect(abs(try AudioFileTools.duration(of: output) - 4) < 0.1)
        // Every half second of the upload is tone; the edges are skipped for encoder ramp-up.
        let levels = try AudioFileTools.windowLevelsDB(of: output)
        #expect(levels.dropFirst().dropLast().allSatisfy { $0 > -30 })
    }

    /// 16 kHz mono Int16 CAF with a 440 Hz tone wherever `isTone` is true, like the recorders write.
    private func writeTrack(to url: URL, seconds: Double, isTone: (Double) -> Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            let time = Double(index) / 16_000
            samples[index] = isTone(time) ? 0.3 * sinf(2 * .pi * 440 * Float(index) / 16_000) : 0
        }
        try file.write(from: buffer)
    }
}
