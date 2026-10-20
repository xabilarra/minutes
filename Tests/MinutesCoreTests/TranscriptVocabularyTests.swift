import Testing
import MinutesCore

@Suite struct TranscriptVocabularyTests {
    @Test func readsTermsSeparatedByCommasSemicolonsOrLinesWithoutDuplicates() {
        let vocabulary = TranscriptVocabulary(" Mobilia, Residelia\n Nexo;; mobilia ,\n\nAitor García ")
        #expect(vocabulary.terms == ["Mobilia", "Residelia", "Nexo", "Aitor García"])
        #expect(TranscriptVocabulary("  ,\n ").terms.isEmpty)
    }

    /// The misspellings of the meeting of 2026-10-20, where Whisper wrote names as they sound.
    @Test func rewritesWordsThatSoundLikeATermWithTheTermsSpelling() {
        let vocabulary = TranscriptVocabulary("Mobilia, Residelia, Xabi, ManyChat")
        #expect(vocabulary.correct("con Movilia directamente") == "con Mobilia directamente")
        #expect(vocabulary.correct("el tema con movilia es") == "el tema con Mobilia es")
        #expect(vocabulary.correct("hablar con Resideria") == "hablar con Residelia")
        #expect(vocabulary.correct("Vale, perfecto Xavi") == "Vale, perfecto Xabi")
        #expect(vocabulary.correct("como lo de Menichat y Instagram") == "como lo de ManyChat y Instagram")
    }

    @Test func keepsPunctuationAndEverythingElseAroundTheWord() {
        let vocabulary = TranscriptVocabulary("Mobilia")
        #expect(vocabulary.correct("¿Movilia? Sí, (movilia).") == "¿Mobilia? Sí, (Mobilia).")
    }

    @Test func leavesWordsThatOnlyLookAlikeUntouched() {
        let vocabulary = TranscriptVocabulary("Mobilia, Residelia, Nexo")
        let text = "la movilidad de la residencia, una inmobiliaria en Nextwork"
        #expect(vocabulary.correct(text) == text)
    }

    @Test func shortTermsOnlyFixCaseAndAccents() {
        let vocabulary = TranscriptVocabulary("Nexo, Aitor")
        #expect(vocabulary.correct("en el nexo, con aítor") == "en el Nexo, con Aitor")
        #expect(vocabulary.correct("con Nexa y Hitor") == "con Nexa y Hitor")
    }

    @Test func aLowercaseTermKeepsTheCapitalOfAWordAtTheStartOfASentence() {
        let vocabulary = TranscriptVocabulary("reel, mobilia")
        #expect(vocabulary.correct("Reel, el reél y el REEL") == "Reel, el reel y el REEL")
        #expect(vocabulary.correct("Movilia") == "mobilia")
    }

    @Test func termsOfSeveralWordsMatchTheSameWordsInARow() {
        let vocabulary = TranscriptVocabulary("Aitor García")
        #expect(vocabulary.correct("habla con aitor garcia mañana") == "habla con Aitor García mañana")
        #expect(vocabulary.correct("aitor, garcia") == "aitor, garcia")
    }

    @Test func termsWithAHyphenOrApostropheMatchWithOrWithoutIt() {
        let vocabulary = TranscriptVocabulary("García-López, O'Neill")
        #expect(vocabulary.correct("con garcia-lopez y garcía lópez") == "con García-López y García-López")
        #expect(vocabulary.correct("habla o'neil hoy") == "habla O'Neill hoy")
        #expect(vocabulary.terms == ["García-López", "O'Neill"])
    }

    @Test func correctsEverySegmentAndKeepsTheRestOfIt() {
        let vocabulary = TranscriptVocabulary("Mobilia")
        let segments = [
            TranscriptSegment(speaker: .me, start: 1, end: 2, text: "con Movilia"),
            TranscriptSegment(speaker: .them, start: 3, end: 4, text: "vale"),
        ]
        #expect(vocabulary.correct(segments) == [
            TranscriptSegment(speaker: .me, start: 1, end: 2, text: "con Mobilia"),
            TranscriptSegment(speaker: .them, start: 3, end: 4, text: "vale"),
        ])
    }

    @Test func anEmptyVocabularyChangesNothing() {
        #expect(TranscriptVocabulary("").correct("con Movilia") == "con Movilia")
    }
}
