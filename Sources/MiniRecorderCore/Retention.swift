import Foundation

/// How long to keep one kind of recording. Nil means forever.
public struct RetentionRule: Codable, Equatable, Sendable {
    /// Days after which the whole recording goes to the Trash.
    public var recordingDays: Int?
    /// Days after which the audio files go to the Trash. The transcript stays.
    public var audioDays: Int?

    public init(recordingDays: Int? = nil, audioDays: Int? = nil) {
        self.recordingDays = recordingDays
        self.audioDays = audioDays
    }
}

/// One retention rule for each kind of recording.
public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var meeting = RetentionRule()
    public var note = RetentionRule()
    public var voice = RetentionRule()

    public init() {}

    public subscript(kind: RecordingKind) -> RetentionRule {
        get {
            switch kind {
            case .meeting: return meeting
            case .note: return note
            case .voice: return voice
            }
        }
        set {
            switch kind {
            case .meeting: meeting = newValue
            case .note: note = newValue
            case .voice: voice = newValue
            }
        }
    }

    /// What the policy removes at `now`. It never touches the recording `activeID`. It keeps the
    /// audio of a recording without a transcript, because the audio is then the only copy.
    public func actions(
        for meetings: [MeetingRecord], now: Date = Date(), excluding activeID: MeetingRecord.ID? = nil
    ) -> [RetentionAction] {
        meetings.compactMap { meeting in
            guard meeting.id != activeID else { return nil }
            let rule = self[meeting.kind]
            let ageInDays = now.timeIntervalSince(meeting.startedAt) / 86_400
            if let days = rule.recordingDays, ageInDays >= Double(days) {
                return .trashRecording(meeting.id)
            }
            if let days = rule.audioDays, meeting.hasAudio, meeting.transcript != nil, ageInDays >= Double(days) {
                return .trashAudio(meeting.id)
            }
            return nil
        }
    }
}

public enum RetentionAction: Equatable, Sendable {
    case trashRecording(MeetingRecord.ID)
    case trashAudio(MeetingRecord.ID)
}
