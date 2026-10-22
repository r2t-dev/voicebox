import FluidAudio
import Foundation

/// A name or term of the custom vocabulary. The transcript spells it as `text`. The aliases are other spellings
/// that the speech model writes for it. The app replaces them with `text` too.
public struct VocabularyTerm: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let aliases: [String]

    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }

    /// Reads the list that the user types. Commas and new lines separate the terms. A colon after a term
    /// starts its aliases, up to the end of the line: "Kubernetes: cube in eighties, cooper netties".
    /// Drops empty terms and terms that occur again with other letter case. Keeps the order.
    public static func parse(_ list: String) -> [VocabularyTerm] {
        var seen = Set<String>()
        var terms: [VocabularyTerm] = []
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let candidates: [VocabularyTerm]
            if parts.count == 2 {
                candidates = [VocabularyTerm(text: cleaned(parts[0]), aliases: items(parts[1]))]
            } else {
                candidates = items(line).map { VocabularyTerm(text: $0) }
            }
            for term in candidates where !term.text.isEmpty && seen.insert(term.text.lowercased()).inserted {
                terms.append(term)
            }
        }
        return terms
    }

    /// The list in the format that `parse` reads, one term per line.
    public static func format(_ terms: [VocabularyTerm]) -> String {
        terms.map { term in
            term.aliases.isEmpty ? term.text : term.text + ": " + term.aliases.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private static func items(_ text: Substring) -> [String] {
        text.split(separator: ",").map(cleaned).filter { !$0.isEmpty }
    }

    private static func cleaned(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}

/// A vocabulary term that takes the place of a run of words in a track.
public struct VocabularyReplacement: Equatable, Sendable {
    /// The indices of the words in `TrackTranscript.words`.
    public let words: Range<Int>
    public let term: String

    public init(words: Range<Int>, term: String) {
        self.words = words
        self.term = term
    }
}

extension TrackTranscript {
    /// The punctuation at the end of a word that the term keeps. The lines of a transcript end at a sentence end.
    private static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]

    /// The transcript with each term in place of its words. The term gets the start of the first word, the end
    /// of the last word, and the punctuation at the end of the last word. A replacement that is empty, that is
    /// outside the words, or that overlaps an earlier replacement does nothing.
    public func replacing(_ replacements: [VocabularyReplacement]) -> TrackTranscript {
        var accepted: [VocabularyReplacement] = []
        for replacement in replacements.sorted(by: { $0.words.lowerBound < $1.words.lowerBound }) {
            guard !replacement.words.isEmpty, replacement.words.lowerBound >= 0,
                replacement.words.upperBound <= words.count,
                accepted.last.map({ $0.words.upperBound <= replacement.words.lowerBound }) ?? true
            else { continue }
            accepted.append(replacement)
        }
        guard !accepted.isEmpty else { return self }

        var result: [TimedWord] = []
        var next = 0
        for replacement in accepted {
            result += words[next..<replacement.words.lowerBound]
            let first = words[replacement.words.lowerBound]
            let last = words[replacement.words.upperBound - 1]
            let punctuation = String(last.text.reversed().prefix { Self.trailingPunctuation.contains($0) }.reversed())
            let text = replacement.term.hasSuffix(punctuation) ? replacement.term : replacement.term + punctuation
            result.append(TimedWord(text: text, start: first.start, end: last.end))
            next = replacement.words.upperBound
        }
        result += words[next...]
        return TrackTranscript(
            text: result.map(\.text).joined(separator: " "), words: result, tokenTimings: tokenTimings)
    }
}

/// Puts the terms of the custom vocabulary into a transcript, with the FluidAudio CTC vocabulary boosting.
/// A second speech model, Parakeet CTC 110M, scores each term and the words that it can replace against the
/// audio. A term replaces the words only if they look like the term and the audio supports the term more.
struct VocabularyBooster: Sendable {
    private let context: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer

    init(terms: [VocabularyTerm], models: CtcModels) async throws {
        let folder = CtcModels.defaultCacheDirectory(for: models.variant)
        let tokenizer = try await CtcTokenizer.load(from: folder)
        // The spotter and the rescorer skip a term without the token ids of the CTC model.
        let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else {
                Log.write("The vocabulary term “\(term.text)” has no CTC tokens. It is left out.")
                return nil
            }
            return CustomVocabularyTerm(
                text: term.text, aliases: term.aliases.isEmpty ? nil : term.aliases, ctcTokenIds: ids)
        }
        context = CustomVocabularyContext(terms: tokenized)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        // The spotter rescue proposes a term from the audio alone, even for words that look nothing like it.
        // In tests it replaced "Please send the report" with a short name, so it is off (FluidAudio #724).
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context, config: VocabularyRescorer.Config(spotterRescueEnabled: false),
            ctcModelDirectory: folder)
    }

    /// The replacements for the transcript of the audio in `url`. The token timings of the transcript and
    /// the audio start at the same time.
    func replacements(for transcript: TrackTranscript, audio url: URL) async throws -> [VocabularyReplacement] {
        guard !context.terms.isEmpty, !transcript.tokenTimings.isEmpty else { return [] }
        let samples = try AudioConverter().resampleAudioFile(url)
        let spotted = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples, customVocabulary: context, minScore: nil)
        guard !spotted.logProbs.isEmpty else { return [] }

        // The same thresholds as the FluidAudio VocabularyBoostingSession.
        let size = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
        let evidence = rescorer.ctcTokenEvaluateCandidates(
            transcript: transcript.text, tokenTimings: transcript.tokenTimings, logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration, cbw: size.cbw, marginSeconds: 0.5,
            minSimilarity: max(size.minSimilarity, context.minSimilarity))
        // The word ranges of the candidates index the words of the rescorer. Both come from the same token timings.
        guard evidence.baseWords == transcript.words.map(\.text) else {
            Log.write("The vocabulary rescorer split the words differently. No term was applied.")
            return []
        }
        // An empty range marks a candidate whose words are not in one run.
        return evidence.candidates
            .filter { $0.legacyOutcome == .applied && !$0.wordRange.isEmpty }
            .map { VocabularyReplacement(words: $0.wordRange, term: $0.canonicalTerm) }
    }
}
