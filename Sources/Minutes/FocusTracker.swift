import AppKit
import CoreGraphics
import MinutesCapture
import MinutesCore
import os

/// Makes a focus-following video recording track the window the user is looking at.
///
/// Polls the window server twice a second (no extra permission: window IDs, owners and layers
/// need neither Accessibility nor window titles) and switches the recording once the same
/// window has been focused on two consecutive polls.
@MainActor
final class FocusTracker {
    private static let pollInterval: Duration = .milliseconds(500)

    private let recorder: WindowVideoRecorder
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "FocusTracker")
    private var task: Task<Void, Never>?

    init(recorder: WindowVideoRecorder, meetingWindowID: UInt32) {
        self.recorder = recorder
        task = Task { [weak self] in
            var debouncer = FocusDebouncer(current: meetingWindowID)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if let target = debouncer.observe(Self.focusedWindowID()) {
                    await self.switchRecording(to: target)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func switchRecording(to windowID: UInt32) async {
        do {
            try await recorder.follow(windowID: windowID)
        } catch {
            logger.error("Could not follow the focused window: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func focusedWindowID() -> UInt32? {
        FocusedWindowPicker.pick(
            among: onScreenWindows(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// On-screen windows, front to back.
    private static func onScreenWindows() -> [ScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber] as? UInt32,
                  let pid = info[kCGWindowOwnerPID] as? Int32,
                  let layer = info[kCGWindowLayer] as? Int,
                  let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return ScreenWindow(
                windowID: id, ownerPID: pid, layer: layer,
                width: Double(bounds.width), height: Double(bounds.height)
            )
        }
    }
}
