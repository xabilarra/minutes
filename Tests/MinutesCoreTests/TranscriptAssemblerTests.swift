import Testing
import MinutesCore

@Suite struct TranscriptAssemblerTests {
    @Test func segmentsAreCleanedMappedToTheTrackAndLabelled() {
        let raw = [
            RawSegment(start: 0, end: 2.5, text: " Hola "),
            RawSegment(start: 3, end: 4, text: ""),
            RawSegment(start: 5, end: 6, text: "¡Suscríbete!"),
        ]
        let chunk = SpeechChunk(index: 1, pieces: [AudioPiece(start: 600, duration: 2.5), AudioPiece(start: 700, duration: 10)])
        #expect(TranscriptAssembler.segments(from: raw, chunk: chunk, speaker: .me) == [
            TranscriptSegment(speaker: .me, start: 600, end: 602.5, text: "Hola"),
        ])
        let later = [RawSegment(start: 3, end: 4.5, text: "Adiós")]
        #expect(TranscriptAssembler.segments(from: later, chunk: chunk, speaker: .them) == [
            TranscriptSegment(speaker: .them, start: 700.5, end: 702, text: "Adiós"),
        ])
    }

    /// The silence cut out between two pieces is not part of a segment that runs across their joint.
    @Test func aSegmentAcrossAJointKeepsItsSpokenLength() {
        let chunk = SpeechChunk(index: 0, pieces: [AudioPiece(start: 600, duration: 2.5), AudioPiece(start: 700, duration: 10)])
        let raw = [RawSegment(start: 2, end: 4, text: "Vale, de acuerdo")]
        #expect(TranscriptAssembler.segments(from: raw, chunk: chunk, speaker: .them) == [
            TranscriptSegment(speaker: .them, start: 602, end: 604, text: "Vale, de acuerdo"),
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
