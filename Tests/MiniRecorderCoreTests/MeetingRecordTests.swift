import Foundation
import Testing

@testable import MiniRecorderCore

struct MeetingRecordTests {
    @Test func parseReadsWhatRenderWrites() {
        let lines = [
            TranscriptLine(start: 2, speaker: "Others", text: "Good morning: this is Daniel."),
            TranscriptLine(start: 3725, speaker: "Me", text: "Thanks."),
        ]
        #expect(TranscriptMerger.parse(TranscriptMerger.render(lines)) == lines)
    }

    @Test func parseJoinsForeignLinesToThePreviousLine() {
        let lines = TranscriptMerger.parse("intro text\n[00:05] Me: first part\nsecond part\n\n[00:09] Others: hi\n")
        #expect(
            lines == [
                TranscriptLine(start: 5, speaker: "Me", text: "first part second part"),
                TranscriptLine(start: 9, speaker: "Others", text: "hi"),
            ])
    }

    @Test func loadAllReturnsMeetingFoldersNewestFirst() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MiniRecorderTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        for name in ["2026-10-21_09-00-00", "2026-10-22_16-32-34", "not-a-meeting"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "[00:02] Others: Hello.\n[00:05] Me: Hi.\n".write(
            to: root.appendingPathComponent("2026-10-22_16-32-34/transcript.txt"), atomically: true, encoding: .utf8)
        try "".write(
            to: root.appendingPathComponent("2026-10-21_09-00-00/transcript.txt"), atomically: true, encoding: .utf8)
        try "log".write(to: root.appendingPathComponent("minirecorder.log"), atomically: true, encoding: .utf8)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        try SessionInfo(startedAt: started, stoppedAt: started + 31, mic: .init(), system: .init())
            .save(to: root.appendingPathComponent("2026-10-22_16-32-34/session.json"))

        let meetings = MeetingRecord.loadAll(in: root)

        #expect(meetings.map(\.id) == ["2026-10-22_16-32-34", "2026-10-21_09-00-00"])
        #expect(meetings[0].lines.map(\.speaker) == ["Others", "Me"])
        #expect(meetings[0].duration == 31)
        #expect(meetings[1].transcript == "" && meetings[1].lines.isEmpty)
        #expect(meetings[1].startedAt == MeetingFolder.date(fromName: "2026-10-21_09-00-00"))
        #expect(!meetings[1].hasAudio)
    }
}
