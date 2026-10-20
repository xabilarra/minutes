import Foundation

/// The user's confirmed spellings (names, brands, jargon), applied to the transcript after Whisper.
///
/// Whisper writes unknown names as they sound ("Movilia" for "Mobilia"). Sending the terms as
/// Whisper's prompt fixes them but, on the meeting of 2026-10-20, also made it invent sentences and
/// drop up to three quarters of a minute's text, so the terms correct the result instead.
public struct TranscriptVocabulary: Sendable {
    /// Terms at least this long (as sounds) also match a word one letter apart; shorter ones match
    /// only the same sounds, so common words are never rewritten into a short term.
    static let minimumFuzzyLength = 6

    public let terms: [String]
    private let entries: [(term: String, wordCount: Int, key: String)]

    /// Terms separated by commas, semicolons or lines; blank entries and repeats (same sounds) are dropped.
    public init(_ text: String) {
        var terms: [String] = []
        var keys: Set<String> = []
        for entry in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let term = entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = Self.termKey(term).key
            guard !key.isEmpty, keys.insert(key).inserted else { continue }
            terms.append(term)
        }
        self.terms = terms
        // Longer terms first, so "Aitor García" wins over "Aitor".
        entries = terms
            .map { term in
                let (wordCount, key) = Self.termKey(term)
                return (term: term, wordCount: wordCount, key: key)
            }
            .sorted { $0.wordCount > $1.wordCount }
    }

    public func correct(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            var corrected = segment
            corrected.text = correct(segment.text)
            return corrected
        }
    }

    /// Replaces each run of words that sounds like a term (words separated only by spaces, hyphens or
    /// apostrophes) with the term as the user wrote it, leaving punctuation and every other character
    /// untouched.
    public func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        let words = Self.wordRanges(in: text)
        var result = ""
        var copiedUpTo = text.startIndex
        var index = 0
        while index < words.count {
            guard let (term, wordCount) = match(at: index, words: words, in: text) else {
                index += 1
                continue
            }
            let range = words[index].lowerBound..<words[index + wordCount - 1].upperBound
            // A lowercase term only fixes spelling: "Reel" opening a sentence keeps its capital.
            let original = text[range]
            let keepsCase = term == term.lowercased() && original.lowercased() == term
            result += text[copiedUpTo..<range.lowerBound] + (keepsCase ? String(original) : term)
            copiedUpTo = range.upperBound
            index += wordCount
        }
        return result + text[copiedUpTo...]
    }

    private func match(at index: Int, words: [Range<String.Index>], in text: String) -> (String, Int)? {
        for entry in entries where index + entry.wordCount <= words.count {
            let window = words[index..<(index + entry.wordCount)]
            let joinedWithinAName = zip(window, window.dropFirst()).allSatisfy { previous, next in
                text[previous.upperBound..<next.lowerBound].allSatisfy { $0.isWhitespace || Self.nameJoiners.contains($0) }
            }
            guard joinedWithinAName else { continue }
            let key = Self.soundKey(window.map { String(text[$0]) }.joined(separator: " "))
            if Self.sounds(key, like: entry.key) { return (entry.term, entry.wordCount) }
        }
        return nil
    }

    /// Characters that join the words of one name ("García-López", "O'Neill") rather than end a phrase.
    private static let nameJoiners: Set<Character> = ["-", "'", "\u{2019}"]

    /// A term's words counted and keyed the way the text's words are, so "García-López" is two words.
    private static func termKey(_ term: String) -> (wordCount: Int, key: String) {
        let words = wordRanges(in: term).map { String(term[$0]) }
        return (words.count, soundKey(words.joined(separator: " ")))
    }

    private static func sounds(_ key: String, like termKey: String) -> Bool {
        if key == termKey { return true }
        guard termKey.count >= minimumFuzzyLength, key.first == termKey.first else { return false }
        return editDistance(Array(key), Array(termKey), limit: 1) <= 1
    }

    /// How a word sounds in Spanish, roughly: no case or accents, b = v, i = y, s = z, silent h,
    /// doubled letters once.
    static func soundKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var key = ""
        for character in folded {
            let sound: Character? = switch character {
            case "h": nil
            case "v": "b"
            case "y": "i"
            case "z": "s"
            default: character.isLetter || character.isNumber || character == " " ? character : nil
            }
            if let sound, sound != key.last || sound == " " { key.append(sound) }
        }
        return key.split(separator: " ").joined(separator: " ")
    }

    /// Ranges of the runs of letters and digits.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil {
                start = index
            } else if !isWordCharacter, let wordStart = start {
                ranges.append(wordStart..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Levenshtein distance, or `limit + 1` as soon as it is known to exceed `limit`.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character], limit: Int) -> Int {
        guard abs(lhs.count - rhs.count) <= limit else { return limit + 1 }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[rhs.count]
    }
}
