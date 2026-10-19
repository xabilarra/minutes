import AppKit
import UserNotifications

/// Posts user notifications for events that happen after the call (transcript ready, failures).
/// Recording start and stop are shown by the on-screen `RecordingIndicator` instead.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let folderKey = "folder"

    /// Lazy: `current()` traps in processes without an app bundle (unit tests).
    private lazy var center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func transcriptReady(folder: URL) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Transcripción lista")
        content.body = folder.lastPathComponent
        content.userInfo = [Self.folderKey: folder.path]
        post(content, identifier: "transcript-\(folder.lastPathComponent)")
    }

    func problem(_ title: String, detail: String, folder: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        if let folder { content.userInfo = [Self.folderKey: folder.path] }
        post(content, identifier: UUID().uuidString)
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let folderPath = response.notification.request.content.userInfo[Self.folderKey] as? String
        await MainActor.run {
            if action == UNNotificationDefaultActionIdentifier, let folderPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: folderPath, isDirectory: true))
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
