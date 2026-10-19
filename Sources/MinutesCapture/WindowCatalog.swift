import Foundation
import ScreenCaptureKit

/// A window that can be recorded, described without retaining any ScreenCaptureKit object.
public struct CapturableWindow: Sendable, Equatable {
    public let windowID: UInt32
    /// Owning application's bundle ID ("" if unknown).
    public let bundleID: String
    /// Window title ("" if none).
    public let title: String
    /// Width in points.
    public let width: Double
    /// Height in points.
    public let height: Double

    public init(windowID: UInt32, bundleID: String, title: String, width: Double, height: Double) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
    }
}

public enum WindowCatalog {
    /// On-screen, normal-layer windows of other applications.
    ///
    /// Requires the Screen Recording permission: without it ScreenCaptureKit throws (mapped to
    /// `CaptureError.permissionDenied`) and the system may show its permission prompt, so
    /// check `CapturePermissions.screenRecordingAuthorized()` before polling.
    public static func onScreenWindows() async throws -> [CapturableWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureErrors.map(error)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication?.processID != ownPID }
            .map { window in
                CapturableWindow(
                    windowID: window.windowID,
                    bundleID: window.owningApplication?.bundleIdentifier ?? "",
                    title: window.title ?? "",
                    width: Double(window.frame.width),
                    height: Double(window.frame.height)
                )
            }
    }
}

/// Maps ScreenCaptureKit errors to `CaptureError` where a specific case applies.
enum ScreenCaptureErrors {
    static func map(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return CaptureError.permissionDenied("screen recording")
        }
        return error
    }
}
