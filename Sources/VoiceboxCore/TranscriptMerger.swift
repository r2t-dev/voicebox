import Foundation

public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptLine: Equatable, Sendable {
    public let start: TimeInterval
    public let speaker: String
    public let text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// A span of time in which one speaker talks, from diarization. Diarization finds who speaks when.
public struct SpeakerTurn: Equatable, Sendable {
    /// The id that the diarizer gives the speaker.
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Turns the word timings of each track into "[mm:ss] Speaker: text" lines ordered by time.
public enum TranscriptMerger {
    /// A pause this long between two words starts a new line.
    public static let pauseThreshold: TimeInterval = 1.0

    /// Cuts one track into lines at sentence ends, at pauses and where the speaker changes.
    /// Without `turns`, every line has the label `speaker`. With `turns`, each word gets the speaker of the turn
    /// that overlaps it most, or of the nearest turn. The labels are then "Speaker 1", "Speaker 2" and so on,
    /// in the order in which the speakers first talk.
    /// `offset` moves the track onto the shared session clock.
    public static func lines(
        from words: [TimedWord], fallbackText: String = "", speaker: String, turns: [SpeakerTurn] = [],
        offset: TimeInterval = 0
    ) -> [TranscriptLine] {
        guard !words.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptLine(start: offset, speaker: speaker, text: text)]
        }

        var lines: [TranscriptLine] = []
        var current: [TimedWord] = []
        var currentSpeaker = speaker
        func flush() {
            guard let first = current.first else { return }
            let text = current.map(\.text).joined(separator: " ")
            lines.append(TranscriptLine(start: first.start + offset, speaker: currentSpeaker, text: text))
            current.removeAll()
        }

        for (word, wordSpeaker) in zip(words, speakerLabels(for: words, turns: turns, fallback: speaker)) {
            if let last = current.last,
                wordSpeaker != currentSpeaker || word.start - last.end >= pauseThreshold || endsSentence(last.text)
            {
                flush()
            }
            currentSpeaker = wordSpeaker
            current.append(word)
        }
        flush()
        return lines
    }

    /// The label of each word: "Speaker 1", "Speaker 2" and so on for the speaker of the turn that overlaps the
    /// word most, or of the nearest turn. Without turns, every word gets `fallback`.
    static func speakerLabels(for words: [TimedWord], turns: [SpeakerTurn], fallback: String) -> [String] {
        var labels: [String: String] = [:]
        return words.map { word in
            guard let id = turns.max(by: { shared(word, $0) < shared(word, $1) })?.speaker else { return fallback }
            if let label = labels[id] { return label }
            let label = "Speaker \(labels.count + 1)"
            labels[id] = label
            return label
        }
    }

    /// The time that a word and a turn have in common. A negative value is the gap between them.
    private static func shared(_ word: TimedWord, _ turn: SpeakerTurn) -> TimeInterval {
        min(word.end, turn.end) - max(word.start, turn.start)
    }

    /// Orders the lines of all tracks by start time. On a tie, the earlier track comes first.
    public static func merge(_ tracks: [[TranscriptLine]]) -> [TranscriptLine] {
        tracks.enumerated()
            .flatMap { trackIndex, lines in lines.map { (trackIndex, $0) } }
            .sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }
            .map(\.1)
    }

    public static func render(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)\n" }.joined()
    }

    /// Reads the lines that `render` writes. A line in another format joins the line before it.
    public static func parse(_ transcript: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        for raw in transcript.split(whereSeparator: \.isNewline) {
            if let line = parseLine(raw) {
                lines.append(line)
            } else if let last = lines.popLast() {
                let text = last.text + " " + raw.trimmingCharacters(in: .whitespaces)
                lines.append(TranscriptLine(start: last.start, speaker: last.speaker, text: text))
            }
        }
        return lines
    }

    private static func parseLine(_ line: Substring) -> TranscriptLine? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        guard stamp.count == 2, let minutes = Int(stamp[0]), let seconds = Int(stamp[1]) else { return nil }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return TranscriptLine(start: TimeInterval(minutes * 60 + seconds), speaker: String(rest[..<colon]), text: text)
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }
}

/// Changes the speaker labels of a transcript, for the dashboard.
public enum SpeakerLabels {
    /// A name without colons and line breaks, which would break the "[mm:ss] Speaker: text" format, and without
    /// outer spaces. Nil if nothing is left.
    public static func cleaned(_ name: String) -> String? {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: ":").union(.newlines))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The speakers in the order in which they first talk.
    public static func speakers(in lines: [TranscriptLine]) -> [String] {
        var seen = Set<String>()
        return lines.map(\.speaker).filter { seen.insert($0).inserted }
    }

    /// True for the labels that the transcription gives: "Me", "Others", "Speaker", and "Speaker 1",
    /// "Speaker 2" and so on.
    public static func isGenerated(_ speaker: String) -> Bool {
        if ["Me", "Others", "Speaker"].contains(speaker) { return true }
        guard speaker.hasPrefix("Speaker "), let number = Int(speaker.dropFirst("Speaker ".count)) else { return false }
        return number > 0
    }

    /// The first of "Speaker 1", "Speaker 2" and so on that the lines do not use.
    public static func unusedName(in lines: [TranscriptLine]) -> String {
        let used = Set(lines.map(\.speaker))
        var number = 1
        while used.contains("Speaker \(number)") { number += 1 }
        return "Speaker \(number)"
    }

    /// Gives every line of `speaker` the label `name`. If `name` is already a speaker, the two become one.
    public static func renaming(_ speaker: String, to name: String, in lines: [TranscriptLine]) -> [TranscriptLine] {
        lines.map { $0.speaker == speaker ? TranscriptLine(start: $0.start, speaker: name, text: $0.text) : $0 }
    }

    /// Gives only the line at `index` the label `name`.
    public static func relabeling(line index: Int, to name: String, in lines: [TranscriptLine]) -> [TranscriptLine] {
        guard lines.indices.contains(index) else { return lines }
        var lines = lines
        lines[index] = TranscriptLine(start: lines[index].start, speaker: name, text: lines[index].text)
        return lines
    }
}

/// Changes the text of a transcript line, for the dashboard.
public enum LineText {
    /// The text as one line, because a line break would start a new transcript line, and without
    /// outer spaces. Nil if nothing is left.
    public static func cleaned(_ text: String) -> String? {
        let cleaned = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Gives the line at `index` the text `text`, and keeps its time and speaker.
    public static func replacing(line index: Int, with text: String, in lines: [TranscriptLine]) -> [TranscriptLine] {
        guard lines.indices.contains(index) else { return lines }
        var lines = lines
        lines[index] = TranscriptLine(start: lines[index].start, speaker: lines[index].speaker, text: text)
        return lines
    }
}
