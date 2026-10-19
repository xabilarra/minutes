import AppKit
import os

/// Developer check: `open -n Minutes.app --args --smoke-test <seconds>` records the frontmost app
/// for that many seconds with detection disabled, waits for transcription, then quits.
@MainActor
struct SmokeTest {
    let seconds: Int

    init?(arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: "--smoke-test") else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        seconds = valueIndex < arguments.endIndex ? Int(arguments[valueIndex]) ?? 20 : 20
    }

    func run(with coordinator: RecordingCoordinator) {
        let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "smoke-test")
        Task {
            try? await Task.sleep(for: .seconds(2))
            logger.notice("Smoke test: recording for \(seconds) s")
            coordinator.startManualRecording()
            try? await Task.sleep(for: .seconds(Double(seconds)))
            await coordinator.stopRecording(manual: true)
            // Status updates hop to the main actor asynchronously; give the queue time to report.
            try? await Task.sleep(for: .seconds(2))
            while !coordinator.isTranscriptionIdle {
                try? await Task.sleep(for: .seconds(1))
            }
            logger.notice("Smoke test: finished")
            NSApp.terminate(nil)
        }
    }
}
