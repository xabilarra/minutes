/// Files inside a meeting folder. Names are part of the accepted on-disk layout (Spanish by spec).
public enum MeetingFile: String, CaseIterable, Sendable {
    /// Meeting window video, native resolution.
    case video = "video.mp4"
    /// Microphone track ("Yo").
    case micAudio = "yo.m4a"
    /// System audio track ("Ellos").
    case systemAudio = "ellos.m4a"
    /// Raw microphone capture, kept until transcription succeeds.
    case micRaw = "yo.caf"
    /// Raw system audio capture, kept until transcription succeeds.
    case systemRaw = "ellos.caf"
    case transcriptMarkdown = "transcripcion.md"
    case transcriptJSON = "transcripcion.json"
    case metadata = "meta.json"
}
