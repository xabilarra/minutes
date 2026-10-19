/// Who spoke a segment, inferred from the track it was transcribed from.
/// Raw values are the speaker labels stored in transcripts (Spanish by spec).
public enum Speaker: String, Codable, Sendable {
    /// Microphone track (the user).
    case me = "Yo"
    /// System audio track (everyone else in the call).
    case them = "Ellos"
}

/// One Whisper segment as returned by the API, times relative to the uploaded chunk.
public struct RawSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var avgLogprob: Double?
    public var noSpeechProb: Double?
    public var compressionRatio: Double?

    public init(
        start: Double,
        end: Double,
        text: String,
        avgLogprob: Double? = nil,
        noSpeechProb: Double? = nil,
        compressionRatio: Double? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
    }
}

/// A cleaned, speaker-labelled segment with times in seconds from the start of the recording.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Speaker, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}
