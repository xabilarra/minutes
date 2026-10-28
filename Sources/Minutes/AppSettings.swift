import Foundation
import MinutesCore

/// UserDefaults keys shared by the menu (via @AppStorage) and the coordinator.
enum SettingsKey {
    static let autoRecord = "autoRecord"
    static let recordVideo = "recordVideo"
    static let videoRetentionDays = "videoRetentionDays"
    static let videoSource = "videoSource"
    static let transcriptionLanguage = "transcriptionLanguage"
    static let transcriptionVocabulary = "transcriptionVocabulary"
    static let didRequestSystemAudio = "didRequestSystemAudio"
}

/// What the meeting video shows.
enum VideoSource: String {
    /// The display the user is looking at, starting with the one showing the meeting: closing or
    /// reopening the meeting window does not stop it.
    case activeDisplay
    /// The window the user is looking at, starting with the meeting: includes what the user presents
    /// from other windows and what others share.
    case focus
    /// Only the meeting window: clean, includes what others share.
    case window
    /// The whole display showing the meeting: also includes what the user presents.
    case display
}

/// Languages offered for transcription (Whisper ISO 639-1 codes); "auto" lets Whisper detect it.
enum TranscriptionLanguage {
    static let automatic = "auto"
    static let options: [(code: String, name: String)] = [
        ("es", "Español"), ("en", "English"), ("ca", "Català"), ("eu", "Euskara"), ("gl", "Galego"),
        ("pt", "Português"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"),
    ]

    /// The system language when it is offered, otherwise automatic detection.
    static var systemDefault: String {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        return options.contains { $0.code == code } ? code : automatic
    }
}

/// Read-only view of the user's preferences.
struct AppSettings {
    var defaults: UserDefaults = .standard

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.autoRecord: true,
            SettingsKey.recordVideo: true,
            SettingsKey.videoRetentionDays: 30,
            SettingsKey.videoSource: VideoSource.activeDisplay.rawValue,
            SettingsKey.transcriptionLanguage: TranscriptionLanguage.systemDefault,
        ])
    }

    var autoRecord: Bool { defaults.bool(forKey: SettingsKey.autoRecord) }
    var recordVideo: Bool { defaults.bool(forKey: SettingsKey.recordVideo) }

    var videoSource: VideoSource {
        VideoSource(rawValue: defaults.string(forKey: SettingsKey.videoSource) ?? "") ?? .activeDisplay
    }

    /// ISO 639-1 code sent to Whisper, or nil to let it detect the language.
    var transcriptionLanguage: String? {
        let code = defaults.string(forKey: SettingsKey.transcriptionLanguage) ?? TranscriptionLanguage.automatic
        return code == TranscriptionLanguage.automatic ? nil : code
    }

    /// Names and terms whose spelling corrects the transcript, separated by commas, semicolons or lines.
    var transcriptionVocabulary: String { defaults.string(forKey: SettingsKey.transcriptionVocabulary) ?? "" }

    /// nil keeps videos forever (stored as 0).
    var videoRetentionDays: Int? {
        let days = defaults.integer(forKey: SettingsKey.videoRetentionDays)
        return days > 0 ? days : nil
    }

    var meetingsRoot: URL { MeetingFolder.defaultRoot }
}
