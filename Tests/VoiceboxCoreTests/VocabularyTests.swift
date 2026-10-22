import Testing

@testable import VoiceboxCore

struct VocabularyTests {
    private func transcript(_ items: [(String, Double, Double)]) -> TrackTranscript {
        let words = items.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
        return TrackTranscript(text: words.map(\.text).joined(separator: " "), words: words)
    }

    @Test func readsTheRowsOfTheTable() {
        let terms = VocabularyTerm.terms(fromRows: [
            (text: " NVIDIA ", aliases: ""),
            (text: "Kubernetes", aliases: " cube in eighties,  cooper netties , ,"),
            (text: "  ", aliases: "alias without a term"),
            (text: "PyTorch", aliases: "pie torch"),
        ])
        #expect(
            terms == [
                VocabularyTerm(text: "NVIDIA"),
                VocabularyTerm(text: "Kubernetes", aliases: ["cube in eighties", "cooper netties"]),
                VocabularyTerm(text: "PyTorch", aliases: ["pie torch"]),
            ])
    }

    @Test func joinsTheAliasesOfARepeatedTerm() {
        let terms = VocabularyTerm.terms(fromRows: [
            (text: "macOS", aliases: "Mac OS"),
            (text: "MACOS", aliases: "mac os, Macos"),
        ])
        #expect(terms == [VocabularyTerm(text: "macOS", aliases: ["Mac OS", "Macos"])])
    }

    @Test func writesTheAliasesThatItReads() {
        let term = VocabularyTerm(text: "macOS", aliases: ["Mac OS", "Macos"])
        #expect(term.aliasList == "Mac OS, Macos")
        #expect(VocabularyTerm.terms(fromRows: [(text: term.text, aliases: term.aliasList)]) == [term])
    }

    @Test func replacesARunOfWordsWithOneTerm() {
        let result = transcript([("We", 0.0, 0.2), ("use", 0.3, 0.5), ("in", 0.6, 0.7), ("video.", 0.8, 1.2)])
            .replacing([VocabularyReplacement(words: 2..<4, term: "NVIDIA")])
        #expect(
            result.words == [
                TimedWord(text: "We", start: 0.0, end: 0.2), TimedWord(text: "use", start: 0.3, end: 0.5),
                TimedWord(text: "NVIDIA.", start: 0.6, end: 1.2),
            ])
        #expect(result.text == "We use NVIDIA.")
    }

    @Test func keepsPunctuationThatTheTermHasItself() {
        let result = transcript([("Yahoo!", 0.0, 0.5)]).replacing([VocabularyReplacement(words: 0..<1, term: "Yahoo!")])
        #expect(result.text == "Yahoo!")
    }

    @Test func skipsOverlappingAndInvalidReplacements() {
        let original = transcript([("a", 0, 1), ("b", 1, 2), ("c", 2, 3)])
        let result = original.replacing([
            VocabularyReplacement(words: 1..<3, term: "Second"),
            VocabularyReplacement(words: 0..<2, term: "First"),
            VocabularyReplacement(words: 2..<5, term: "Outside"),
            VocabularyReplacement(words: 1..<1, term: "Empty"),
        ])
        #expect(result.text == "First c")
        #expect(original.replacing([]).text == original.text)
    }
}
