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

/// Turns the word timings of each track into "[mm:ss] Speaker: text" lines ordered by time.
public enum TranscriptMerger {
    /// A pause this long between two words starts a new line.
    public static let pauseThreshold: TimeInterval = 1.0

    /// Cuts one track into lines at sentence ends and at pauses.
    /// `offset` moves the track onto the shared session clock.
    public static func lines(
        from words: [TimedWord], fallbackText: String = "", speaker: String, offset: TimeInterval = 0
    ) -> [TranscriptLine] {
        guard !words.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptLine(start: offset, speaker: speaker, text: text)]
        }

        var lines: [TranscriptLine] = []
        var current: [TimedWord] = []
        func flush() {
            guard let first = current.first else { return }
            let text = current.map(\.text).joined(separator: " ")
            lines.append(TranscriptLine(start: first.start + offset, speaker: speaker, text: text))
            current.removeAll()
        }

        for word in words {
            if let last = current.last, word.start - last.end >= pauseThreshold || endsSentence(last.text) {
                flush()
            }
            current.append(word)
        }
        flush()
        return lines
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
