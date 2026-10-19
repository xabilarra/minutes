import CoreAudio
import Darwin
import Foundation

/// Errors thrown by the capture layer.
///
/// Messages are deliberately free of file paths, window titles and other
/// user content so they can be shown or logged without leaking meeting data.
public enum CaptureError: Error, LocalizedError {
    /// A Core Audio (or AVAudioEngine) call returned a non-zero `OSStatus`.
    case coreAudio(operation: String, status: OSStatus)
    /// The user has not granted a privacy permission (TCC) that capture needs.
    case permissionDenied(String)
    /// The window with this `CGWindowID` is not (or no longer) available.
    case windowNotFound(UInt32)
    /// Writing or reading a media file failed.
    case writer(String)
    /// The requested operation is not possible in the current state or environment.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "Core Audio operation \(operation) failed with status \(status)\(Self.fourCharacterSuffix(status))."
        case let .permissionDenied(what):
            return "Permission denied: \(what)."
        case let .windowNotFound(windowID):
            return "Window \(windowID) is not available for capture."
        case let .writer(message):
            return "Media file error: \(message)"
        case let .unsupported(message):
            return "Unsupported: \(message)"
        }
    }

    /// Core Audio statuses are often four-character codes ('!obj', 'nope'); show them when printable.
    private static func fourCharacterSuffix(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return " ('\(String(decoding: bytes, as: UTF8.self))')"
    }
}

/// Helpers for the Mach host clock (`mach_absolute_time`), the common timeline shared by
/// Core Audio (`AudioTimeStamp.mHostTime`), AVAudioEngine (`AVAudioTime.hostTime`) and
/// ScreenCaptureKit sample buffers (presentation times on the host time clock).
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current host time in ticks.
    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    /// Signed difference `end - start` in seconds (negative when `end` precedes `start`).
    public static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? seconds(end - start) : -seconds(start - end)
    }

    /// Converts a host-time tick count to seconds.
    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Converts a duration in seconds to host-time ticks (negative and non-finite values map to 0).
    static func ticks(fromSeconds seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
}
