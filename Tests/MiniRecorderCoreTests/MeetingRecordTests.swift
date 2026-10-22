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
        #expect(meetings[1].title == nil && meetings[1].tags.isEmpty)
    }

    @Test func normalizesTitlesAndTags() {
        #expect(MeetingInfo.normalizedTitle("  Weekly sync \n") == "Weekly sync")
        #expect(MeetingInfo.normalizedTitle("   ") == nil)
        #expect(
            MeetingInfo.normalizedTags([" design ", "#Review", "", "Design", "##", "client call"])
                == ["design", "Review", "client call"])
    }

    @Test func savesAndLoadsTitleAndTags() throws {
        let fileManager = FileManager.default
        let folder = MeetingFolder(
            url: fileManager.temporaryDirectory.appendingPathComponent("MiniRecorderTests-\(UUID().uuidString)"))
        try fileManager.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder.url) }
        try "[00:01] Me: Hi.\n".write(to: folder.transcriptURL, atomically: true, encoding: .utf8)

        try MeetingInfo(title: " Design review ", tags: ["ux", "UX", "#q4"]).save(to: folder.infoURL)
        let meeting = MeetingRecord.load(folder)

        #expect(meeting.title == "Design review")
        #expect(meeting.tags == ["ux", "q4"])
        #expect(meeting.hasTag("Q4") && !meeting.hasTag("design"))
        #expect(MeetingInfo.load(from: folder.url.appendingPathComponent("missing.json")) == MeetingInfo())
    }
}
