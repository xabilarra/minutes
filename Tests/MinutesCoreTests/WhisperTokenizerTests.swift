import Foundation
import Testing
import MinutesCore

/// The vocabulary the app bundles (Resources/whisper-multilingual.tiktoken).
let bundledVocabularyURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Resources/whisper-multilingual.tiktoken")

@Suite struct WhisperTokenizerTests {
    @Test func bundledVocabularyDecodesWhisperTextTokens() throws {
        let tokenizer = try WhisperTokenizer(contentsOf: bundledVocabularyURL)
        // " hay según que chat", as whisper-large-v3 emitted it on a real meeting.
        #expect(tokenizer.text(of: [4842, 36570, 631, 5081]) == " hay según que chat")
        #expect(tokenizer.text(of: [3841, 15137, 4023, 30]) == " ¿Qué tal?")
    }

    @Test func timestampAndSpecialTokensAreSkipped() throws {
        let tokenizer = try WhisperTokenizer(contentsOf: bundledVocabularyURL)
        #expect(tokenizer.text(of: [50639, 22637, 13, 50740, 50257]) == " Hola.")
    }

    @Test func tokensThatDoNotFormValidUTF8OrAreUnknownDecodeToNil() throws {
        let tokenizer = try WhisperTokenizer(contentsOf: bundledVocabularyURL)
        // 127 is the lone lead byte 0xC3 of "é"; without its continuation byte the text is not UTF-8.
        #expect(tokenizer.text(of: [631, 127]) == nil)
        #expect(tokenizer.text(of: [-1]) == nil)
        #expect(tokenizer.text(of: []) == nil)
        #expect(tokenizer.text(of: [50639, 50740]) == nil)
    }

    @Test func readsTheTiktokenFormat() throws {
        // "IHF1ZQ==" is " que", "w6k=" is "é"; blank lines are ignored.
        let tokenizer = try WhisperTokenizer(tiktoken: "IHF1ZQ== 0\n\nw6k= 1\n")
        #expect(tokenizer.text(of: [0, 1]) == " queé")
        #expect(throws: WhisperTokenizer.LoadError.malformedLine(1)) { try WhisperTokenizer(tiktoken: "IHF1ZQ==\n") }
        #expect(throws: WhisperTokenizer.LoadError.malformedLine(2)) { try WhisperTokenizer(tiktoken: "IHF1ZQ== 0\n!!! 1\n") }
    }
}
