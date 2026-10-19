import Testing
import MinutesCore

@Suite struct TranscriptAssemblerTests {
    @Test func segmentsAreCleanedOffsetByTheChunkStartAndLabelled() {
        let raw = [
            RawSegment(start: 0, end: 2.5, text: " Hola "),
            RawSegment(start: 3, end: 4, text: ""),
            RawSegment(start: 5, end: 6, text: "¡Suscríbete!"),
        ]
        #expect(TranscriptAssembler.segments(from: raw, chunkStart: 600, speaker: .me) == [
            TranscriptSegment(speaker: .me, start: 600, end: 602.5, text: "Hola"),
        ])
    }

    @Test func assembleSortsByStartPuttingSystemAudioFirstOnTies() {
        let me = [
            TranscriptSegment(speaker: .me, start: 5, end: 6, text: "a"),
            TranscriptSegment(speaker: .me, start: 1, end: 2, text: "b"),
        ]
        let them = [
            TranscriptSegment(speaker: .them, start: 5, end: 6, text: "c"),
            TranscriptSegment(speaker: .them, start: 0, end: 1, text: "d"),
        ]
        #expect(TranscriptAssembler.assemble(me: me, them: them).map(\.text) == ["d", "b", "c", "a"])
    }

    @Test func assembleRemovesMicrophoneEchoes() {
        let remote = TranscriptSegment(speaker: .them, start: 10, end: 14, text: "Vale, entonces revisamos el presupuesto")
        let echo = TranscriptSegment(speaker: .me, start: 10.4, end: 14.2, text: "entonces revisamos el presupuesto")
        #expect(TranscriptAssembler.assemble(me: [echo], them: [remote]) == [remote])
    }
}
