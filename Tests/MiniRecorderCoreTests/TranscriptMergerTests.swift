import Testing

@testable import MiniRecorderCore

struct TranscriptMergerTests {
    private func words(_ items: [(String, Double, Double)]) -> [TimedWord] {
        items.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func cutsLinesAtSentenceEndsAndPauses() {
        let lines = TranscriptMerger.lines(
            from: words([
                ("Hello", 0.5, 0.9), ("there.", 1.0, 1.4),
                ("How", 1.6, 1.8), ("are", 1.9, 2.0), ("you", 2.1, 2.3),
                ("today", 4.0, 4.4),
            ]),
            speaker: "Me")
        #expect(lines.map(\.text) == ["Hello there.", "How are you", "today"])
        #expect(lines.map(\.start) == [0.5, 1.6, 4.0])
    }

    @Test func mergesTracksByStartTimeWithOffsets() {
        let me = TranscriptMerger.lines(from: words([("Hi.", 1.0, 1.3), ("Fine.", 70.0, 70.5)]), speaker: "Me")
        let others = TranscriptMerger.lines(
            from: words([("Hello.", 0.0, 0.4), ("How", 2.0, 2.2), ("are", 2.3, 2.4), ("you?", 2.5, 2.8)]),
            speaker: "Others", offset: 0.5)
        let text = TranscriptMerger.render(TranscriptMerger.merge([me, others]))
        #expect(
            text == """
                [00:00] Others: Hello.
                [00:01] Me: Hi.
                [00:02] Others: How are you?
                [01:10] Me: Fine.

                """)
    }

    @Test func tieKeepsTrackOrder() {
        let me = [TranscriptLine(start: 3, speaker: "Me", text: "a")]
        let others = [TranscriptLine(start: 3, speaker: "Others", text: "b")]
        #expect(TranscriptMerger.merge([me, others]).map(\.speaker) == ["Me", "Others"])
    }

    @Test func usesTextWhenThereAreNoTimings() {
        let lines = TranscriptMerger.lines(from: [], fallbackText: " some text ", speaker: "Others", offset: 2)
        #expect(lines == [TranscriptLine(start: 2, speaker: "Others", text: "some text")])
        #expect(TranscriptMerger.lines(from: [], fallbackText: "  ", speaker: "Me").isEmpty)
    }

    @Test func formatsTimestampsPastOneHour() {
        #expect(TranscriptMerger.timestamp(59.9) == "00:59")
        #expect(TranscriptMerger.timestamp(3725) == "62:05")
    }
}
