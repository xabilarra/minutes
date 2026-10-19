import Testing
import MinutesCore

@Suite struct SpeechPlanTests {
    private let loud = -30.0, quiet = -70.0

    @Test func keepsOnlyTheSpeechWithASecondOfContextOnEachSide() {
        // 0.5 s windows: 5 s silence, 2 s speech, 10 s silence, 1 s speech, 2 s silence.
        let levels = Array(repeating: quiet, count: 10) + Array(repeating: loud, count: 4)
            + Array(repeating: quiet, count: 20) + Array(repeating: loud, count: 2) + Array(repeating: quiet, count: 4)
        #expect(SpeechPlan.pieces(levels: levels, totalDuration: 20) == [
            AudioPiece(start: 4, duration: 4),
            AudioPiece(start: 16, duration: 3),
        ])
    }

    @Test func pausesShorterThanTheMinimumSilenceStayInsideThePiece() {
        // 1 s speech, 2.5 s pause, 1 s speech.
        let levels = [loud, loud, quiet, quiet, quiet, quiet, quiet, loud, loud]
        #expect(SpeechPlan.pieces(levels: levels, totalDuration: 4.5) == [AudioPiece(start: 0, duration: 4.5)])
    }

    @Test func aWindowAtTheThresholdIsSilenceAndASilentTrackHasNoPieces() {
        #expect(SpeechPlan.pieces(levels: [-50, -50], totalDuration: 1).isEmpty)
        #expect(SpeechPlan.pieces(levels: Array(repeating: quiet, count: 100), totalDuration: 50).isEmpty)
        #expect(SpeechPlan.pieces(levels: [], totalDuration: 0).isEmpty)
    }

    @Test func theLastWindowIsClampedToTheTrack() {
        #expect(SpeechPlan.pieces(levels: [quiet, quiet, quiet, quiet, loud], totalDuration: 2.25) == [
            AudioPiece(start: 1, duration: 1.25),
        ])
    }

    @Test func packsPiecesIntoChunksWithoutSplittingAPieceThatFitsInTheNext() {
        let pieces = [
            AudioPiece(start: 0, duration: 300), AudioPiece(start: 400, duration: 250),
            AudioPiece(start: 700, duration: 100),
        ]
        #expect(SpeechPlan.chunks(pieces) == [
            SpeechChunk(index: 0, pieces: [AudioPiece(start: 0, duration: 300), AudioPiece(start: 400, duration: 250)]),
            SpeechChunk(index: 1, pieces: [AudioPiece(start: 700, duration: 100)]),
        ])
    }

    @Test func splitsOnlyAPieceLongerThanTheChunkLength() {
        let chunks = SpeechPlan.chunks(
            [AudioPiece(start: 0, duration: 100), AudioPiece(start: 200, duration: 1300)], chunkLength: 600)
        #expect(chunks == [
            SpeechChunk(index: 0, pieces: [AudioPiece(start: 0, duration: 100), AudioPiece(start: 200, duration: 500)]),
            SpeechChunk(index: 1, pieces: [AudioPiece(start: 700, duration: 600)]),
            SpeechChunk(index: 2, pieces: [AudioPiece(start: 1300, duration: 200)]),
        ])
        #expect(chunks.allSatisfy { $0.duration <= 600 })
    }

    /// Groq bills a sliver as 10 s and Whisper tends to hallucinate on it.
    @Test func aSplitRemainderShorterThanTheMinimumTailStaysInThePreviousChunk() {
        #expect(SpeechPlan.chunks([AudioPiece(start: 0, duration: 1200.3)]) == [
            SpeechChunk(index: 0, pieces: [AudioPiece(start: 0, duration: 600)]),
            SpeechChunk(index: 1, pieces: [AudioPiece(start: 600, duration: 600.3)]),
        ])
        #expect(SpeechPlan.chunks([AudioPiece(start: 0, duration: 1202)]).map(\.duration) == [600, 600, 2])
    }

    @Test func aFullChunkNeverGetsAnEmptyPiece() {
        let chunks = SpeechPlan.chunks([AudioPiece(start: 0, duration: 600), AudioPiece(start: 1000, duration: 700)])
        #expect(chunks == [
            SpeechChunk(index: 0, pieces: [AudioPiece(start: 0, duration: 600)]),
            SpeechChunk(index: 1, pieces: [AudioPiece(start: 1000, duration: 600)]),
            SpeechChunk(index: 2, pieces: [AudioPiece(start: 1600, duration: 100)]),
        ])
    }

    @Test func mapsUploadedTimesBackToTheTrack() {
        let chunk = SpeechChunk(index: 0, pieces: [AudioPiece(start: 10, duration: 5), AudioPiece(start: 60, duration: 5)])
        #expect(chunk.trackTime(0) == 10)
        #expect(chunk.trackTime(2.5) == 12.5)
        #expect(chunk.trackTime(5) == 60)
        #expect(chunk.trackTime(5, isEnd: true) == 15)
        #expect(chunk.trackTime(7) == 62)
        #expect(chunk.trackTime(12) == 65)
    }
}
