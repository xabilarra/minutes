import Testing
import MinutesCore

@Suite struct ChunkPlanTests {
    @Test func coversTheWholeDurationWithChunksOfAtMostTheChunkLength() {
        #expect(ChunkPlan.chunks(totalDuration: 1500) == [
            AudioChunk(index: 0, start: 0, duration: 600),
            AudioChunk(index: 1, start: 600, duration: 600),
            AudioChunk(index: 2, start: 1200, duration: 300),
        ])
        #expect(ChunkPlan.chunks(totalDuration: 25, chunkLength: 10) == [
            AudioChunk(index: 0, start: 0, duration: 10),
            AudioChunk(index: 1, start: 10, duration: 10),
            AudioChunk(index: 2, start: 20, duration: 5),
        ])
    }

    @Test func mergesAFinalRemainderShorterThanTheMinimumTailIntoThePreviousChunk() {
        #expect(ChunkPlan.chunks(totalDuration: 1201.5) == [
            AudioChunk(index: 0, start: 0, duration: 600),
            AudioChunk(index: 1, start: 600, duration: 601.5),
        ])
        #expect(ChunkPlan.chunks(totalDuration: 1202) == [
            AudioChunk(index: 0, start: 0, duration: 600),
            AudioChunk(index: 1, start: 600, duration: 600),
            AudioChunk(index: 2, start: 1200, duration: 2),
        ])
    }

    @Test func shortRecordingIsOneChunkAndNonPositiveDurationIsNone() {
        #expect(ChunkPlan.chunks(totalDuration: 1.5) == [AudioChunk(index: 0, start: 0, duration: 1.5)])
        #expect(ChunkPlan.chunks(totalDuration: 0).isEmpty)
        #expect(ChunkPlan.chunks(totalDuration: -3).isEmpty)
    }
}
