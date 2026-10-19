import AppKit
import CoreAudio
import Foundation

/// Polls which processes currently have audio input running.
///
/// Reads Core Audio process objects (`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+).
/// This needs no privacy permission and does not open any audio device, so it is cheap
/// enough to call every second.
public final class MicUsageMonitor: @unchecked Sendable {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    /// Bundle IDs of processes whose `kAudioProcessPropertyIsRunningInput` is non-zero,
    /// excluding this process. When Core Audio has no bundle ID for a process, the running
    /// application's bundle ID is used instead. Returns `[]` on any error.
    ///
    /// Note: browsers and some apps capture audio from helper processes, so the reported
    /// ID can be a helper's (for example `com.google.Chrome.helper`).
    public func activeInputBundleIDs() -> Set<String> {
        let processes = (try? CoreAudioSupport.array(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            element: AudioObjectID(kAudioObjectUnknown)
        )) ?? []

        var bundleIDs = Set<String>()
        for process in processes {
            let isRunningInput = (try? CoreAudioSupport.value(
                of: process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)
            )) ?? 0
            guard isRunningInput != 0 else { continue }

            let pid = (try? CoreAudioSupport.value(of: process, kAudioProcessPropertyPID, initial: pid_t(-1))) ?? -1
            guard pid != ownPID else { continue }

            var bundleID = (try? CoreAudioSupport.string(of: process, kAudioProcessPropertyBundleID)) ?? ""
            if bundleID.isEmpty, pid > 0 {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            if !bundleID.isEmpty {
                bundleIDs.insert(bundleID)
            }
        }
        return bundleIDs
    }
}
