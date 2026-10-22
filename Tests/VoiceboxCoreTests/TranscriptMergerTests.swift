import Testing

@testable import VoiceboxCore

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

    @Test func namesSpeakersInTheOrderInWhichTheyFirstTalk() {
        let turns = [
            SpeakerTurn(speaker: "S2", start: 0.0, end: 1.5),
            SpeakerTurn(speaker: "S0", start: 1.5, end: 3.0),
            SpeakerTurn(speaker: "S2", start: 3.0, end: 4.0),
        ]
        let lines = TranscriptMerger.lines(
            from: words([("Hi", 0.2, 0.5), ("all", 0.6, 1.0), ("Hello", 1.6, 2.0), ("Bye.", 3.2, 3.5)]),
            speaker: "Others", turns: turns, offset: 10)
        #expect(
            lines == [
                TranscriptLine(start: 10.2, speaker: "Speaker 1", text: "Hi all"),
                TranscriptLine(start: 11.6, speaker: "Speaker 2", text: "Hello"),
                TranscriptLine(start: 13.2, speaker: "Speaker 1", text: "Bye."),
            ])
    }

    @Test func givesAWordTheTurnThatOverlapsItMostOrTheNearestTurn() {
        let turns = [SpeakerTurn(speaker: "A", start: 0.0, end: 1.0), SpeakerTurn(speaker: "B", start: 1.0, end: 2.0)]
        // "most" overlaps B for 0.4 s and A for 0.3 s. "after" is 0.5 s after B. "before" is 0.1 s before A.
        let labels = TranscriptMerger.speakerLabels(
            for: words([("most", 0.7, 1.4), ("after", 2.5, 2.6), ("before", -0.3, -0.1)]), turns: turns,
            fallback: "Others")
        #expect(labels == ["Speaker 1", "Speaker 1", "Speaker 2"])
    }

    @Test func usesTheFallbackLabelWithoutTurns() {
        let lines = TranscriptMerger.lines(from: words([("Hi.", 0.0, 0.3)]), speaker: "Others", turns: [])
        #expect(lines.map(\.speaker) == ["Others"])
    }

    @Test func cleansSpeakerNames() {
        #expect(SpeakerLabels.cleaned("  Anna  Smith ") == "Anna Smith")
        #expect(SpeakerLabels.cleaned("Dr: Who\nelse") == "Dr Who else")
        #expect(SpeakerLabels.cleaned(" : \n ") == nil)
    }

    @Test func knowsTheLabelsThatTheTranscriptionGives() {
        for label in ["Me", "Others", "Speaker", "Speaker 1", "Speaker 12"] {
            #expect(SpeakerLabels.isGenerated(label), "\(label)")
        }
        for label in ["Anna", "Speaker 0", "Speaker x", "Speaker 1a", "speaker 1", "Me too"] {
            #expect(!SpeakerLabels.isGenerated(label), "\(label)")
        }
    }

    @Test func renamesASpeakerInEveryLineAndJoinsSpeakers() {
        let lines = [
            TranscriptLine(start: 0, speaker: "Speaker 2", text: "a"),
            TranscriptLine(start: 1, speaker: "Me", text: "b"),
            TranscriptLine(start: 2, speaker: "Speaker 1", text: "c"),
            TranscriptLine(start: 3, speaker: "Speaker 2", text: "d"),
        ]
        #expect(SpeakerLabels.speakers(in: lines) == ["Speaker 2", "Me", "Speaker 1"])
        #expect(SpeakerLabels.unusedName(in: lines) == "Speaker 3")
        let renamed = SpeakerLabels.renaming("Speaker 2", to: "Anna", in: lines)
        #expect(renamed.map(\.speaker) == ["Anna", "Me", "Speaker 1", "Anna"])
        #expect(renamed.map(\.text) == ["a", "b", "c", "d"])
        let joined = SpeakerLabels.renaming("Speaker 1", to: "Anna", in: renamed)
        #expect(SpeakerLabels.speakers(in: joined) == ["Anna", "Me"])
    }

    @Test func givesOneLineAnotherSpeaker() {
        let lines = [
            TranscriptLine(start: 0, speaker: "Speaker 1", text: "a"),
            TranscriptLine(start: 1, speaker: "Speaker 1", text: "b"),
        ]
        #expect(SpeakerLabels.relabeling(line: 1, to: "Me", in: lines).map(\.speaker) == ["Speaker 1", "Me"])
        #expect(SpeakerLabels.relabeling(line: 5, to: "Me", in: lines) == lines)
    }

    @Test func cleansTheTextOfALine() {
        #expect(LineText.cleaned("  Hello,\nworld.  ") == "Hello, world.")
        #expect(LineText.cleaned("Time: 10:30") == "Time: 10:30")
        #expect(LineText.cleaned(" \n ") == nil)
    }

    @Test func replacesTheTextOfOneLine() {
        let lines = [
            TranscriptLine(start: 1, speaker: "Me", text: "helo"),
            TranscriptLine(start: 2, speaker: "Speaker 1", text: "hi"),
        ]
        let edited = LineText.replacing(line: 0, with: "Hello.", in: lines)
        #expect(edited[0] == TranscriptLine(start: 1, speaker: "Me", text: "Hello."))
        #expect(edited[1] == lines[1])
        #expect(LineText.replacing(line: 2, with: "x", in: lines) == lines)
        // A colon in the text survives a save and a load.
        let saved = TranscriptMerger.render(LineText.replacing(line: 1, with: "At 10:30: done", in: lines))
        #expect(TranscriptMerger.parse(saved)[1].text == "At 10:30: done")
    }

    @Test func formatsTimestampsPastOneHour() {
        #expect(TranscriptMerger.timestamp(59.9) == "00:59")
        #expect(TranscriptMerger.timestamp(3725) == "62:05")
    }
}
