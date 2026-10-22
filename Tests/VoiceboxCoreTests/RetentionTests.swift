import Foundation
import Testing

@testable import VoiceboxCore

struct RetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ id: String, kind: RecordingKind, daysOld: Double, hasAudio: Bool = true, transcript: String? = "text"
    ) -> MeetingRecord {
        MeetingRecord(
            folder: MeetingFolder(url: URL(fileURLWithPath: "/tmp/\(id)")), kind: kind,
            startedAt: now - daysOld * 86_400, duration: nil, session: nil, transcript: transcript, lines: [],
            hasAudio: hasAudio, title: nil, tags: [], linesEdited: false)
    }

    @Test func keepsEverythingByDefault() {
        let meetings = [record("a", kind: .meeting, daysOld: 400), record("b", kind: .voice, daysOld: 400)]
        #expect(RetentionPolicy().actions(for: meetings, now: now).isEmpty)
    }

    @Test func appliesTheRuleOfEachKind() {
        var policy = RetentionPolicy()
        policy.meeting = RetentionRule(recordingDays: 90, audioDays: 7)
        policy.voice = RetentionRule(recordingDays: 1)
        let meetings = [
            record("old-meeting", kind: .meeting, daysOld: 100),
            record("week-old-meeting", kind: .meeting, daysOld: 8),
            record("new-meeting", kind: .meeting, daysOld: 2),
            record("old-note", kind: .note, daysOld: 100),
            record("old-voice", kind: .voice, daysOld: 1.5, hasAudio: false),
            record("new-voice", kind: .voice, daysOld: 0.5, hasAudio: false),
        ]
        #expect(
            policy.actions(for: meetings, now: now) == [
                .trashRecording("old-meeting"),
                .trashAudio("week-old-meeting"),
                .trashRecording("old-voice"),
            ])
    }

    @Test func protectsTheActiveRecordingAndAudioWithoutTranscript() {
        var policy = RetentionPolicy()
        policy.note = RetentionRule(recordingDays: 30, audioDays: 1)
        let meetings = [
            record("active", kind: .note, daysOld: 40),
            record("untranscribed", kind: .note, daysOld: 5, transcript: nil),
            record("audio-gone", kind: .note, daysOld: 5, hasAudio: false),
        ]
        #expect(policy.actions(for: meetings, now: now, excluding: "active").isEmpty)
    }
}
