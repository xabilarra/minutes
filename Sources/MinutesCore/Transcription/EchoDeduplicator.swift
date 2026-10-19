/// Drops microphone segments that merely repeat the remote side.
///
/// Without echo cancellation, speakers playing the call are picked up by the microphone, so the
/// same sentence is transcribed twice: once from system audio ("Ellos") and once from the mic ("Yo").
/// An echo is heard at the same time as the original and repeats its words in the same order, so
/// both conditions are required; a reply that starts after the remote speaker stops is never an echo.
public enum EchoDeduplicator {
    /// Below this many tokens, overlap ratios are too noisy ("sí", "vale") and only exact matches count.
    static let minimumTokensForOverlapRatio = 4

    /// Removes `.me` segments that are echoes of `.them` audio picked up by the microphone.
    ///
    /// A `.me` segment is an echo when the `.them` segments overlapping it in time cover at least
    /// `minimumOverlap` of its duration and, taking those segments' normalized tokens in time order,
    /// the longest common subsequence with its own tokens is at least `threshold` of its tokens.
    /// Segments with fewer than 4 tokens are echoes only when their normalized text equals one
    /// overlapping `.them` segment. `.them` segments are never removed. Order preserved.
    public static func dedupe(
        _ segments: [TranscriptSegment], threshold: Double = 0.6, minimumOverlap: Double = 0.5
    ) -> [TranscriptSegment] {
        let remote = segments
            .filter { $0.speaker == .them }
            .sorted { $0.start < $1.start }
            .map { (segment: $0, normalized: SegmentFilter.normalize($0.text)) }

        return segments.filter { segment in
            guard segment.speaker == .me else { return true }
            let overlapping = remote.filter { overlap(segment, $0.segment) > 0 }
            guard !overlapping.isEmpty,
                  overlapRatio(segment, overlapping.map(\.segment)) >= minimumOverlap
            else { return true }
            return !isEcho(SegmentFilter.normalize(segment.text), of: overlapping.map(\.normalized), threshold: threshold)
        }
    }

    private static func overlap(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    /// Share of the mic segment's duration covered by remote speech (1 for zero-length segments).
    private static func overlapRatio(_ microphone: TranscriptSegment, _ remote: [TranscriptSegment]) -> Double {
        let duration = microphone.end - microphone.start
        guard duration > 0 else { return 1 }
        let covered = remote.reduce(0) { $0 + overlap(microphone, $1) }
        return min(1, covered / duration)
    }

    private static func isEcho(_ microphone: String, of remote: [String], threshold: Double) -> Bool {
        let tokens = microphone.split(separator: " ")
        guard tokens.count >= minimumTokensForOverlapRatio else {
            return remote.contains(microphone)
        }
        let remoteTokens = remote.flatMap { $0.split(separator: " ") }
        let matched = longestCommonSubsequence(tokens, remoteTokens)
        return Double(matched) / Double(tokens.count) >= threshold
    }

    private static func longestCommonSubsequence(_ a: [Substring], _ b: [Substring]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for tokenA in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, tokenB) in b.enumerated() {
                current[j + 1] = tokenA == tokenB ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }
}
