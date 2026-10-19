import Foundation

/// Sample state used to capture the README screenshots:
/// `open Minutes.app --args --showcase <recording|ending|ready>` (see scripts/capture-screenshots.sh).
/// It never starts detection, touches devices or files, or calls the network.
enum ShowcaseScene: String, CaseIterable {
    /// The indicator while a call is being recorded.
    case recording
    /// The indicator right after hanging up, with the stop countdown.
    case ending
    /// The transcript is ready: the indicator offers copying it, and the window shows the last meeting.
    case ready

    init?(arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: "--showcase") else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex, let scene = ShowcaseScene(rawValue: arguments[valueIndex]) else {
            self = .ready
            return
        }
        self = scene
    }

    static let appName = "Google Meet"
    static let meetingName = "2026-10-20 10.30 Weekly sync (Google Meet)"
}
