import CoreAudio
import Foundation

/// Thin, typed wrappers over the Core Audio C property API.
///
/// Every failure is reported as `CaptureError.coreAudio(operation:status:)` naming the
/// property selector, so callers can surface a precise diagnostic.
enum CoreAudioSupport {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size (POD) property value.
    static func value<T>(
        of objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        initial: T
    ) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "get \(fourCC(selector))", status: status)
        }
        return value
    }

    /// Reads a variable-length array property (for example a list of object IDs).
    static func array<T>(
        of objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        element: T
    ) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "size \(fourCC(selector))", status: status)
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: element, count: count)
        status = values.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "get \(fourCC(selector))", status: status)
        }
        // The list may shrink between the size query and the read.
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a `CFString` property. Core Audio returns a +1 reference that the caller owns.
    static func string(of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "get \(fourCC(selector))", status: status)
        }
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Translates a Unix PID into its Core Audio process object (`kAudioObjectUnknown` if none).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifier,
            &size,
            &objectID
        )
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "translate PID to process object", status: status)
        }
        return objectID
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let deviceID = try value(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioDeviceID(kAudioObjectUnknown)
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CaptureError.unsupported("there is no default output device")
        }
        return deviceID
    }

    static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        try string(of: deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Registers a property listener block; returns a token that removes it.
    static func addListener(
        to objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) throws -> PropertyListenerToken {
        var address = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: "add listener \(fourCC(selector))", status: status)
        }
        return PropertyListenerToken(objectID: objectID, address: address, queue: queue, block: block)
    }

    /// Renders a selector such as `'prs#'` for diagnostics.
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(value) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

/// Keeps the exact block instance Core Audio needs to remove a listener.
struct PropertyListenerToken {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    /// Removes the listener. Errors are ignored: the object may already be gone.
    func remove() {
        var address = address
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
