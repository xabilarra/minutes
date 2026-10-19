import Foundation

/// Where a meeting's transcription stands; failures keep their error so they can be retried.
public struct TranscriptionStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending, transcribing, done, failed
    }

    public var state: State
    public var model: String?
    public var language: String?
    /// Last failure message, for display and retry decisions. Never contains secrets.
    public var error: String?
    public var completedAt: Date?

    public init(state: State, model: String? = nil, language: String? = nil, error: String? = nil, completedAt: Date? = nil) {
        self.state = state
        self.model = model
        self.language = language
        self.error = error
        self.completedAt = completedAt
    }
}

/// Contents of a meeting's `meta.json`.
public struct MeetingMetadata: Codable, Equatable, Sendable {
    /// Schema written by this version; bump when the stored format changes incompatibly.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var appName: String
    public var appBundleID: String?
    /// Cleaned meeting title (see `MeetingTitle.clean`), nil when only generic titles were seen.
    public var title: String?
    /// Raw title of the recorded window.
    public var windowTitle: String?
    /// "auto" (detected meeting) or "manual" (started by the user).
    public var trigger: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double?
    /// Video timeline start minus audio timeline start, in seconds.
    public var videoOffsetSeconds: Double?
    public var hasVideo: Bool
    public var transcription: TranscriptionStatus

    public init(
        appName: String,
        appBundleID: String?,
        title: String?,
        windowTitle: String?,
        trigger: String,
        startedAt: Date,
        hasVideo: Bool,
        transcription: TranscriptionStatus = .init(state: .pending)
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.appName = appName
        self.appBundleID = appBundleID
        self.title = title
        self.windowTitle = windowTitle
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = nil
        self.durationSeconds = nil
        self.videoOffsetSeconds = nil
        self.hasVideo = hasVideo
        self.transcription = transcription
    }
}
