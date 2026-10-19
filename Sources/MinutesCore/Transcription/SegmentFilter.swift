import Foundation

/// Removes Whisper output that is not speech: silence guesses, repetition loops and known hallucinations.
public enum SegmentFilter {
    /// Whisper's own no-speech heuristic: high no-speech probability AND low confidence.
    static let noSpeechProbabilityLimit = 0.6
    static let averageLogProbabilityLimit = -1.0
    /// Above this gzip compression ratio a segment is a repetition loop.
    static let compressionRatioLimit = 2.4

    /// Normalized phrases Whisper emits over silence or noise (mostly subtitle credits from its training data).
    static let hallucinations: Set<String> = [
        "subtitulos realizados por la comunidad de amaraorg",
        "subtitulos por la comunidad de amaraorg",
        "gracias por ver el video",
        "gracias por ver",
        "por ver el video",
        "suscribete",
        "suscribete al canal",
        "musica",
        "thank you for watching",
        "thanks for watching",
        "amaraorg",
    ]
    /// Any segment mentioning Amara.org is a subtitle credit.
    static let hallucinationMarker = "amaraorg"

    /// Drops: blank text; segments with noSpeechProb > 0.6 AND avgLogprob < -1.0 (Whisper no-speech heuristic); compressionRatio > 2.4; segments whose normalized text (lowercased, diacritics and punctuation removed, whitespace collapsed) is a known Whisper hallucination: "subtitulos realizados por la comunidad de amaraorg", "subtitulos por la comunidad de amaraorg", "gracias por ver el video", "gracias por ver", "por ver el video", "suscribete", "suscribete al canal", "musica", "thank you for watching", "thanks for watching", "amaraorg" (and normalized contains "amaraorg" anywhere). Trims surrounding whitespace of kept text.
    ///
    /// Text that normalizes to nothing (only punctuation or symbols, e.g. "...") counts as blank.
    public static func clean(_ segments: [RawSegment]) -> [RawSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalize(text)
            guard !normalized.isEmpty,
                  !isLikelySilence(segment),
                  !isRepetitionLoop(segment),
                  !isHallucination(normalized) else {
                return nil
            }
            var kept = segment
            kept.text = text
            return kept
        }
    }

    /// Lowercases, removes diacritics, punctuation and symbols, and collapses whitespace to single spaces.
    public static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if !CharacterSet.punctuationCharacters.contains(scalar), !CharacterSet.symbols.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func isLikelySilence(_ segment: RawSegment) -> Bool {
        guard let noSpeech = segment.noSpeechProb, let logprob = segment.avgLogprob else { return false }
        return noSpeech > noSpeechProbabilityLimit && logprob < averageLogProbabilityLimit
    }

    private static func isRepetitionLoop(_ segment: RawSegment) -> Bool {
        (segment.compressionRatio ?? 0) > compressionRatioLimit
    }

    private static func isHallucination(_ normalized: String) -> Bool {
        hallucinations.contains(normalized) || normalized.contains(hallucinationMarker)
    }
}
