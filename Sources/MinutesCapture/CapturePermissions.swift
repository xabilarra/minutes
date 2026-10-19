import AVFoundation
import CoreGraphics
import Foundation

/// Privacy (TCC) permission checks and requests used by capture.
///
/// System audio capture (Core Audio process taps) has no public preflight API: macOS asks
/// the first time a tap is used and, when denied, the tap delivers silence.
public enum CapturePermissions {
    /// Whether microphone access is granted.
    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for microphone access when undetermined; returns whether access is granted.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Whether Screen Recording access is granted (no prompt).
    public static func screenRecordingAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording access (opens the system prompt or settings the first time).
    /// A grant typically takes effect only after the app relaunches.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
