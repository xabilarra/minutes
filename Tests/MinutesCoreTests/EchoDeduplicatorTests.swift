import Testing
import MinutesCore

@Suite struct EchoDeduplicatorTests {
    private func me(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: .me, start: start, end: end, text: text)
    }

    private func them(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: .them, start: start, end: end, text: text)
    }

    @Test func dropsMicSegmentsThatRepeatOverlappingSystemAudioAndKeepsOrder() {
        let remote = them(10, 14, "Vale, entonces revisamos el presupuesto mañana")
        let echo = me(10.5, 14.5, "entonces revisamos el presupuesto mañana")
        let own = me(20, 22, "Perfecto, lo preparo yo")
        let remoteAgain = them(10, 14, "Vale, entonces revisamos el presupuesto mañana")
        #expect(EchoDeduplicator.dedupe([remote, echo, own, remoteAgain]) == [remote, own, remoteAgain])
    }

    @Test func dropsMicSegmentsOnlyWhenAtLeastTheThresholdOfTokensMatchInOrder() {
        let remote = them(0, 5, "uno dos tres")
        let atThreshold = me(0, 5, "uno dos tres cuatro cinco")
        let belowThreshold = me(0, 5, "uno dos seis cuatro cinco")
        #expect(EchoDeduplicator.dedupe([remote, atThreshold, belowThreshold]) == [remote, belowThreshold])
    }

    @Test func requiresTheMicSegmentToOverlapSystemAudioForHalfItsDuration() {
        let text = "revisamos el presupuesto mañana por la tarde"
        let halfOverlap = [them(12, 18, text), me(10, 14, text)]
        #expect(EchoDeduplicator.dedupe(halfOverlap) == [halfOverlap[0]])
        let lessThanHalf = [them(12.1, 18, text), me(10, 14, text)]
        #expect(EchoDeduplicator.dedupe(lessThanHalf) == lessThanHalf)
    }

    @Test func shortMicSegmentsAreDroppedOnlyOnAnExactNormalizedMatch() {
        let remote = them(0, 2, "sí, claro")
        let exactEcho = me(0.2, 1.8, "¡Sí, claro!")
        let partial = me(0.2, 1.8, "claro")
        #expect(EchoDeduplicator.dedupe([remote, exactEcho, partial]) == [remote, partial])
    }

    @Test(arguments: [
        ("¿Lo tendrás listo para el lunes?", "Sí, lo tengo listo para el lunes"),
        ("¿Te va bien el martes a las cinco?", "El martes a las cinco me va bien"),
        ("¿Cuántas unidades necesitas al mes? ¿Cien?", "Cien unidades al mes, sin problema"),
        ("Lo vemos el jueves, ¿vale?", "Vale, el jueves lo vemos"),
    ])
    func keepsGenuineRepliesThatStartRightAfterTheRemoteSpeaker(question: String, reply: String) {
        let segments = [them(0, 5, question), me(5.6, 8.5, reply)]
        #expect(EchoDeduplicator.dedupe(segments) == segments)
    }

    @Test func keepsOverlappingMicSpeechThatReusesTheWordsInAnotherOrder() {
        let segments = [them(0, 5, "lo vemos el jueves vale"), me(0.5, 4.5, "vale el jueves lo vemos")]
        #expect(EchoDeduplicator.dedupe(segments) == segments)
    }
}
