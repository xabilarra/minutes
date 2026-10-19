import Foundation

/// Renders the stored transcript files: Markdown for reading/agents and JSON with exact segments.
public enum TranscriptRenderer {
    /// Same-speaker segments separated by at most this many seconds form one turn.
    static let turnJoinGap: Double = 2.0
    static let emptyTranscriptLine = "_Sin transcripción (no se detectó voz)._"

    /// Markdown for agents (see format below).
    ///
    /// ```
    /// # <title ?? appName> — <yyyy-MM-dd HH:mm>
    ///
    /// - App: <appName>
    /// - Duración: <HH:MM:SS of durationSeconds, or "desconocida">
    /// - Vídeo: video.mp4 (desfase <+0.4> s)        ← only when hasVideo
    /// - Audio: yo.m4a (Yo), ellos.m4a (Ellos)
    ///
    /// ## Transcripción
    ///
    /// [00:00:03] Ellos: Hola, ¿me oyes?
    /// [00:00:05] Yo: Sí, perfecto.
    /// ```
    /// Consecutive segments of the same speaker whose gap (next.start - previous.end) <= 2.0 s are joined
    /// into one line with a single space, using the first segment's timestamp. Empty transcript → the line
    /// "_Sin transcripción (no se detectó voz)._". File ends with a single newline.
    public static func markdown(_ segments: [TranscriptSegment], metadata: MeetingMetadata, timeZone: TimeZone = .current) -> String {
        let title = metadata.title.map(singleLine).flatMap { $0.isEmpty ? nil : $0 } ?? metadata.appName
        let started = LocalDateFormat.string(from: metadata.startedAt, format: "yyyy-MM-dd HH:mm", timeZone: timeZone)

        var lines = [
            "# \(title) — \(started)",
            "",
            "- App: \(metadata.appName)",
            "- Duración: \(metadata.durationSeconds.map(timestamp) ?? "desconocida")",
        ]
        if metadata.hasVideo {
            lines.append("- Vídeo: \(MeetingFile.video.rawValue) (desfase \(signedTenths(metadata.videoOffsetSeconds)) s)")
        }
        lines += [
            "- Audio: \(MeetingFile.micAudio.rawValue) (\(Speaker.me.rawValue)), "
                + "\(MeetingFile.systemAudio.rawValue) (\(Speaker.them.rawValue))",
            "",
            "## Transcripción",
            "",
        ]

        let turns = speakerTurns(segments)
        if turns.isEmpty {
            lines.append(emptyTranscriptLine)
        } else {
            lines += turns.map { "[\(timestamp($0.start))] \($0.speaker.rawValue): \($0.texts.joined(separator: " "))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// {"meeting": <MeetingMetadata>, "segments": [TranscriptSegment]} pretty printed, sorted keys, ISO 8601 dates.
    public static func json(_ segments: [TranscriptSegment], metadata: MeetingMetadata) throws -> Data {
        try MinutesJSON.makeEncoder().encode(TranscriptDocument(meeting: metadata, segments: segments))
    }

    /// "HH:MM:SS" (hours not wrapped at 24), floor of seconds, negative clamped to 0.
    ///
    /// Non-finite values also render as "00:00:00".
    public static func timestamp(_ seconds: Double) -> String {
        // Clamped well below Int overflow; Int32.max seconds is about 68 years.
        let total = seconds.isFinite && seconds > 0 ? Int(min(seconds, Double(Int32.max)).rounded(.down)) : 0
        return String(format: "%02ld:%02ld:%02ld", total / 3600, (total % 3600) / 60, total % 60)
    }

    private struct TranscriptDocument: Encodable {
        let meeting: MeetingMetadata
        let segments: [TranscriptSegment]
    }

    private struct Turn {
        let speaker: Speaker
        let start: Double
        var end: Double
        var texts: [String]
    }

    private static func speakerTurns(_ segments: [TranscriptSegment]) -> [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            let text = singleLine(segment.text)
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speaker == segment.speaker, segment.start - last.end <= turnJoinGap {
                last.texts.append(text)
                last.end = segment.end
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: segment.speaker, start: segment.start, end: segment.end, texts: [text]))
            }
        }
        return turns
    }

    /// Collapses newlines and runs of whitespace so one segment always stays on one Markdown line.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "+0.4", "-1.3"; nil and values that round to zero render as "+0.0".
    private static func signedTenths(_ seconds: Double?) -> String {
        let tenths = ((seconds ?? 0) * 10).rounded()
        guard tenths.isFinite, tenths != 0 else { return "+0.0" }
        return String(format: "%+.1f", tenths / 10)
    }
}
