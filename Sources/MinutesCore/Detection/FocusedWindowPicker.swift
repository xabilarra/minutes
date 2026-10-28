import CoreGraphics
import Foundation

/// A window as listed by the window server, front to back (`CGWindowListCopyWindowInfo`).
public struct ScreenWindow: Equatable, Sendable {
    public let windowID: UInt32
    public let ownerPID: Int32
    /// Window level; 0 is the normal layer, higher values are floating panels, menus and overlays.
    public let layer: Int
    /// Width in points.
    public let width: Double
    /// Height in points.
    public let height: Double

    public init(windowID: UInt32, ownerPID: Int32, layer: Int, width: Double, height: Double) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.width = width
        self.height = height
    }
}

/// Picks the window the user is looking at, for video that follows the focus.
public enum FocusedWindowPicker {
    /// Topmost normal-layer window of the frontmost app, at least 300x200 points (see
    /// `MeetingWindowSelector`), from `windows` ordered front to back. nil when the frontmost app
    /// is unknown, is `excludingPID` (this app) or has no such window, so the caller keeps the
    /// current window.
    public static func pick(among windows: [ScreenWindow], frontmostPID: Int32?, excludingPID: Int32) -> UInt32? {
        guard let frontmostPID, frontmostPID != excludingPID else { return nil }
        return windows.first { window in
            window.ownerPID == frontmostPID
                && window.layer == 0
                && window.width >= MeetingWindowSelector.minimumWidth
                && window.height >= MeetingWindowSelector.minimumHeight
        }?.windowID
    }
}

/// Switches to a new focused window only after it is seen on two consecutive polls, so passing
/// through apps with Cmd-Tab does not make the video flicker.
public struct FocusDebouncer: Sendable {
    public private(set) var current: UInt32
    private var pending: UInt32?

    public init(current: UInt32) {
        self.current = current
    }

    /// Feeds one poll's focused window (nil keeps the current one); returns the window to switch to.
    public mutating func observe(_ candidate: UInt32?) -> UInt32? {
        guard let candidate, candidate != current else {
            pending = nil
            return nil
        }
        guard pending == candidate else {
            pending = candidate
            return nil
        }
        pending = nil
        current = candidate
        return candidate
    }

    /// Records a switch made elsewhere (for example back to the meeting window) and drops any pending one.
    public mutating func reset(to window: UInt32) {
        current = window
        pending = nil
    }
}

/// Picks the display the user is looking at, for video that follows the focus across displays.
public enum FocusedDisplayPicker {
    /// Display containing the center of `windowFrame`, or the one holding most of it when the center
    /// is on none. Frames use the window server's global coordinates. nil when `windowFrame` is nil
    /// or on no display, so the caller keeps the current display.
    public static func pick(windowFrame: CGRect?, displays: [(id: UInt32, frame: CGRect)]) -> UInt32? {
        guard let windowFrame else { return nil }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let display = displays.first(where: { $0.frame.contains(center) }) {
            return display.id
        }
        func overlap(_ frame: CGRect) -> CGFloat {
            let shared = frame.intersection(windowFrame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = displays.max(by: { overlap($0.frame) < overlap($1.frame) }), overlap(best.frame) > 0 else {
            return nil
        }
        return best.id
    }
}
