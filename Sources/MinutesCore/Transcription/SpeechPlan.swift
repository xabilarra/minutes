/// A stretch of a track, in seconds from the start of the track.
public struct AudioPiece: Equatable, Sendable {
    public let start: Double
    public let duration: Double

    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }
}

/// One upload: the pieces of a track that contain speech, played back to back.
///
/// Groq bills by seconds of audio and its free plan caps them per hour, so the silence between
/// pieces (the other side talking, pauses) is never sent.
public struct SpeechChunk: Equatable, Sendable {
    public let index: Int
    public let pieces: [AudioPiece]

    public init(index: Int, pieces: [AudioPiece]) {
        self.index = index
        self.pieces = pieces
    }

    /// Seconds of audio uploaded for this chunk.
    public var duration: Double { pieces.reduce(0) { $0 + $1.duration } }

    /// Maps a time in the uploaded audio back to the track. A time on the joint of two pieces maps to
    /// the start of the later piece, or to the end of the earlier one when `isEnd` (a segment's end).
    /// Times past the uploaded audio map to the end of the last piece.
    public func trackTime(_ time: Double, isEnd: Bool = false) -> Double {
        var offset = 0.0
        for piece in pieces {
            let pieceEnd = offset + piece.duration
            if time < pieceEnd || (isEnd && time <= pieceEnd) {
                return piece.start + max(0, time - offset)
            }
            offset = pieceEnd
        }
        return pieces.last?.end ?? 0
    }
}

/// Finds the speech in a track from its loudness and packs it into uploads.
public enum SpeechPlan {
    /// Speech pieces from the loudness of consecutive windows of `windowDuration` seconds (dBFS, as
    /// `AudioFileTools.windowLevelsDB` measures them). A window louder than `thresholdDB` is speech;
    /// silences shorter than `minimumSilence` stay inside a piece, and each piece keeps `padding`
    /// seconds of context on both sides, clamped to `[0, totalDuration)`.
    ///
    /// The default threshold is the one that already drops segments over silence, so nothing quieter
    /// than what the transcript would keep is cut. On the meetings of 2026-10-19 these defaults kept
    /// about 45% of the audio, and every transcribed segment still overlapped a piece.
    public static func pieces(
        levels: [Double],
        windowDuration: Double = 0.5,
        totalDuration: Double,
        thresholdDB: Double = -50,
        minimumSilence: Double = 3,
        padding: Double = 1
    ) -> [AudioPiece] {
        guard windowDuration > 0, totalDuration > 0 else { return [] }
        var ranges: [(start: Double, end: Double)] = []
        for (index, level) in levels.enumerated() where level > thresholdDB {
            let start = Double(index) * windowDuration
            let end = min(totalDuration, start + windowDuration)
            guard start < end else { break }
            if let last = ranges.last, start - last.end < minimumSilence {
                ranges[ranges.count - 1].end = end
            } else {
                ranges.append((start, end))
            }
        }
        var padded: [(start: Double, end: Double)] = []
        for range in ranges {
            let start = max(0, range.start - padding), end = min(totalDuration, range.end + padding)
            if let last = padded.last, start <= last.end {
                padded[padded.count - 1].end = end
            } else {
                padded.append((start, end))
            }
        }
        return padded.map { AudioPiece(start: $0.start, duration: $0.end - $0.start) }
    }

    /// Packs pieces in order into chunks of at most `chunkLength` seconds of audio (Groq's 25 MB
    /// attachment limit). A piece that does not fit starts a new chunk; only a piece longer than
    /// `chunkLength` is split, and a split remainder shorter than `minimumTail` stays in the chunk
    /// before it, which Groq would otherwise bill as 10 s and Whisper tends to hallucinate on.
    public static func chunks(_ pieces: [AudioPiece], chunkLength: Double = 600, minimumTail: Double = 2) -> [SpeechChunk] {
        guard chunkLength > 0 else { return [] }
        var chunks: [[AudioPiece]] = []
        var current: [AudioPiece] = []
        var currentDuration = 0.0
        func close() {
            if !current.isEmpty { chunks.append(current) }
            current = []
            currentDuration = 0
        }
        for piece in pieces where piece.duration > 0 {
            if currentDuration + piece.duration > chunkLength, piece.duration <= chunkLength {
                close()
            }
            var rest = piece
            while currentDuration + rest.duration > chunkLength {
                let fits = chunkLength - currentDuration
                if rest.duration - fits < minimumTail { break }
                if fits > 0 { current.append(AudioPiece(start: rest.start, duration: fits)) }
                close()
                rest = AudioPiece(start: rest.start + fits, duration: rest.duration - fits)
            }
            if rest.duration > 0 {
                current.append(rest)
                currentDuration += rest.duration
            }
        }
        close()
        return chunks.enumerated().map { SpeechChunk(index: $0.offset, pieces: $0.element) }
    }
}
