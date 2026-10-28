import AppKit
import CoreGraphics
import MinutesCapture
import MinutesCore
import os

/// Makes a focus-following video recording track the window, or the display, the user is looking at.
///
/// Polls the window server twice a second (no extra permission: window IDs, owners, layers and
/// bounds need neither Accessibility nor window titles) and switches the recording once the same
/// window or display has been focused on two consecutive polls.
@MainActor
final class FocusTracker {
    private static let pollInterval: Duration = .milliseconds(500)

    private let recorder: WindowVideoRecorder
    private let logger = Logger(subsystem: "io.github.xabilarra.Minutes", category: "FocusTracker")
    private var task: Task<Void, Never>?

    /// Follows the focused window, starting with the meeting window.
    init(recorder: WindowVideoRecorder, meetingWindowID: UInt32) {
        self.recorder = recorder
        poll(startingWith: meetingWindowID, focusedTarget: { Self.focusedWindow()?.windowID }) { recorder, windowID in
            try await recorder.follow(windowID: windowID)
        }
    }

    /// Follows the display showing the focused window, starting with `displayID`.
    init(recorder: WindowVideoRecorder, displayID: UInt32) {
        self.recorder = recorder
        poll(startingWith: displayID, focusedTarget: { Self.focusedDisplayID() }) { recorder, displayID in
            try await recorder.follow(displayID: displayID)
        }
    }

    private func poll(
        startingWith current: UInt32,
        focusedTarget: @escaping @MainActor () -> UInt32?,
        switchTo: @escaping @MainActor (WindowVideoRecorder, UInt32) async throws -> Void
    ) {
        task = Task { [weak self] in
            var debouncer = FocusDebouncer(current: current)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if let target = debouncer.observe(focusedTarget()) {
                    do {
                        try await switchTo(self.recorder, target)
                    } catch {
                        self.logger.error("Could not follow the focus: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func focusedWindow() -> (windowID: UInt32, frame: CGRect)? {
        let windows = onScreenWindows()
        let id = FocusedWindowPicker.pick(
            among: windows.map(\.window),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        return windows.first { $0.window.windowID == id }.map { ($0.window.windowID, $0.frame) }
    }

    private static func focusedDisplayID() -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        let displays = ids.prefix(Int(count)).map { (id: $0, frame: CGDisplayBounds($0)) }
        return FocusedDisplayPicker.pick(windowFrame: focusedWindow()?.frame, displays: displays)
    }

    /// On-screen windows, front to back, with their frames in global coordinates.
    private static func onScreenWindows() -> [(window: ScreenWindow, frame: CGRect)] {
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
            let window = ScreenWindow(
                windowID: id, ownerPID: pid, layer: layer,
                width: Double(bounds.width), height: Double(bounds.height)
            )
            return (window, bounds)
        }
    }
}
