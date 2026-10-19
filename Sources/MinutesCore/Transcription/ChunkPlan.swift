/// A slice of an audio track to upload on its own, in seconds from the start of the track.
public struct AudioChunk: Equatable, Sendable {
    public let index: Int
    public let start: Double
    public let duration: Double

    public init(index: Int, start: Double, duration: Double) {
        self.index = index
        self.start = start
        self.duration = duration
    }
}

/// Splits long tracks into uploads that stay under Groq's 25 MB attachment limit.
public enum ChunkPlan {
    /// Consecutive chunks covering [0, totalDuration) of at most chunkLength seconds; a final remainder shorter than minimumTail (default 2 s) is merged into the previous chunk. Empty for totalDuration <= 0.
    ///
    /// The merge avoids uploading a sliver that Groq bills as 10 s and Whisper tends to hallucinate on.
    public static func chunks(totalDuration: Double, chunkLength: Double = 600, minimumTail: Double = 2) -> [AudioChunk] {
        guard totalDuration.isFinite, totalDuration > 0, chunkLength.isFinite, chunkLength > 0 else {
            return []
        }
        let count = Int((totalDuration / chunkLength).rounded(.up))
        // Starts are computed from the index (not accumulated) so floating-point error cannot drift.
        var chunks = (0..<count).map { index in
            let start = Double(index) * chunkLength
            return AudioChunk(index: index, start: start, duration: min(chunkLength, totalDuration - start))
        }
        if chunks.count >= 2, let tail = chunks.last, tail.duration < minimumTail {
            chunks.removeLast()
            let previous = chunks.removeLast()
            chunks.append(AudioChunk(index: previous.index, start: previous.start, duration: totalDuration - previous.start))
        }
        return chunks
    }
}
