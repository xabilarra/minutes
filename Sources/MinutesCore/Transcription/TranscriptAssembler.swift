/// Turns per-chunk Whisper output of both tracks into one speaker-labelled timeline.
public enum TranscriptAssembler {
    /// Applies SegmentFilter.clean, then offsets by chunkStart and labels with speaker.
    public static func segments(from raw: [RawSegment], chunkStart: Double, speaker: Speaker) -> [TranscriptSegment] {
        SegmentFilter.clean(raw).map { segment in
            TranscriptSegment(
                speaker: speaker,
                start: segment.start + chunkStart,
                end: segment.end + chunkStart,
                text: segment.text
            )
        }
    }

    /// Merges both speakers sorted by start (ties: them first), then EchoDeduplicator.dedupe.
    ///
    /// The sort is stable: segments with the same start and speaker keep their input order.
    public static func assemble(me: [TranscriptSegment], them: [TranscriptSegment]) -> [TranscriptSegment] {
        let merged = (them + me).enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start {
                return lhs.element.start < rhs.element.start
            }
            if lhs.element.speaker != rhs.element.speaker {
                return lhs.element.speaker == .them
            }
            return lhs.offset < rhs.offset
        }
        return EchoDeduplicator.dedupe(merged.map(\.element))
    }
}
