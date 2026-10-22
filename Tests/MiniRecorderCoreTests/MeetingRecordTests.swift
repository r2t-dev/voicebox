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

    @Test func readsTheKindAndKeepsVoiceInputAsPlainText() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MiniRecorderTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(_ name: String, kind: RecordingKind?, transcript: String) throws -> MeetingRecord {
            let folder = MeetingFolder(url: root.appendingPathComponent(name))
            try fileManager.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try transcript.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
            if let kind {
                try SessionInfo(kind: kind, startedAt: started, stoppedAt: started + 3, mic: .init(), system: .init())
                    .save(to: folder.sessionURL)
            }
            return MeetingRecord.load(folder)
        }

        let voice = try meeting("voice", kind: .voice, transcript: "Send the report: today.\n")
        #expect(voice.kind == .voice && voice.lines.isEmpty)
        #expect(voice.preview == "Send the report: today." && !voice.hasNoSpeech)

        let note = try meeting("note", kind: .note, transcript: "[00:01] Speaker: Hello.\n")
        #expect(note.kind == .note && note.preview == "Speaker: Hello.")

        let old = try meeting("old", kind: nil, transcript: "")
        #expect(old.kind == .meeting && old.hasNoSpeech)
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

    @Test func knowsWhenTheUserChangedTheLines() throws {
        let fileManager = FileManager.default
        let folder = MeetingFolder(
            url: fileManager.temporaryDirectory.appendingPathComponent("MiniRecorderTests-\(UUID().uuidString)"))
        try fileManager.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder.url) }

        try "[00:01] Me: Hi.\n[00:02] Speaker 2: Hello.\n".write(
            to: folder.transcriptURL, atomically: true, encoding: .utf8)
        #expect(!MeetingRecord.load(folder).linesEdited)

        // A meeting.json from before the flag has no "linesEdited" key.
        try #"{"tags": ["ux"]}"#.write(to: folder.infoURL, atomically: true, encoding: .utf8)
        #expect(MeetingInfo.load(from: folder.infoURL) == MeetingInfo(tags: ["ux"]))

        try MeetingInfo(title: "Review", linesEdited: true).save(to: folder.infoURL)
        #expect(MeetingInfo.load(from: folder.infoURL).linesEdited)
        #expect(MeetingRecord.load(folder).linesEdited)

        // Without the flag, a name that the transcription does not give is a change too.
        try MeetingInfo(title: "Review").save(to: folder.infoURL)
        try "[00:01] Me: Hi.\n[00:02] Anna: Hello.\n".write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        #expect(MeetingRecord.load(folder).linesEdited)
    }
}
