import Testing
import MinutesCore

@Suite struct SegmentFilterTests {
    private func texts(_ segments: [RawSegment]) -> [String] { segments.map(\.text) }

    @Test func normalizeLowercasesAndRemovesDiacriticsPunctuationAndExtraWhitespace() {
        #expect(SegmentFilter.normalize("  ¡Hola,   CÓMO \n estás?  ") == "hola como estas")
        #expect(SegmentFilter.normalize("Amara.org") == "amaraorg")
        #expect(SegmentFilter.normalize("[Música]") == "musica")
    }

    @Test func dropsBlankSegments() {
        let cleaned = SegmentFilter.clean([
            RawSegment(start: 0, end: 1, text: ""),
            RawSegment(start: 1, end: 2, text: "   \n"),
            RawSegment(start: 2, end: 3, text: "..."),
            RawSegment(start: 3, end: 4, text: "Hola"),
        ])
        #expect(texts(cleaned) == ["Hola"])
    }

    @Test func dropsSegmentsWhisperConsidersSilent() {
        let cleaned = SegmentFilter.clean([
            RawSegment(start: 0, end: 1, text: "silencio", avgLogprob: -1.2, noSpeechProb: 0.7),
            RawSegment(start: 1, end: 2, text: "confiado", avgLogprob: -0.5, noSpeechProb: 0.7),
            RawSegment(start: 2, end: 3, text: "probable voz", avgLogprob: -1.5, noSpeechProb: 0.5),
            RawSegment(start: 3, end: 4, text: "en el límite", avgLogprob: -1.0, noSpeechProb: 0.6),
            RawSegment(start: 4, end: 5, text: "sin datos"),
        ])
        #expect(texts(cleaned) == ["confiado", "probable voz", "en el límite", "sin datos"])
    }

    @Test func dropsRepetitiveSegmentsByCompressionRatio() {
        let cleaned = SegmentFilter.clean([
            RawSegment(start: 0, end: 1, text: "sí sí sí sí sí sí", compressionRatio: 2.5),
            RawSegment(start: 1, end: 2, text: "normal", compressionRatio: 2.4),
        ])
        #expect(texts(cleaned) == ["normal"])
    }

    @Test func dropsKnownWhisperHallucinations() {
        let hallucinations = [
            "Subtítulos realizados por la comunidad de Amara.org",
            "Subtítulos por la comunidad de Amara.org",
            "Gracias por ver el video.",
            "¡Gracias por ver!",
            "¡Suscríbete!",
            "Suscríbete al canal.",
            "[Música]",
            "Thank you for watching!",
            "Thanks for watching.",
            "Amara.org",
            "Subtítulos hechos por Pepe para Amara.org",
        ]
        let segments = hallucinations.enumerated().map { RawSegment(start: Double($0), end: Double($0) + 1, text: $1) }
            + [RawSegment(start: 50, end: 51, text: "Gracias por venir.")]
        #expect(texts(SegmentFilter.clean(segments)) == ["Gracias por venir."])
    }

    @Test func keptSegmentsHaveTheirTextTrimmed() {
        let segment = RawSegment(start: 1, end: 2, text: "  Hola, ¿qué tal?\n", avgLogprob: -0.2, noSpeechProb: 0.1, compressionRatio: 1.1)
        #expect(SegmentFilter.clean([segment]) == [
            RawSegment(start: 1, end: 2, text: "Hola, ¿qué tal?", avgLogprob: -0.2, noSpeechProb: 0.1, compressionRatio: 1.1),
        ])
    }

    @Test func dropsTheTruncatedThanksForWatchingHallucination() {
        let segment = RawSegment(start: 90, end: 122.7, text: " por ver el video", avgLogprob: -0.4, noSpeechProb: 0.2, compressionRatio: 1.0)
        #expect(SegmentFilter.clean([segment]).isEmpty)
    }
}
