import AVFoundation
import VoiceboxCore

/// The meetings in ~/Voicebox, for the dashboard.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    func reload() {
        meetings = MeetingRecord.loadAll()
    }

    /// Every tag in use, once, sorted. Tags that differ only in letter case count as one tag.
    var allTags: [String] {
        MeetingInfo.normalizedTags(meetings.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func moveToTrash(_ meeting: MeetingRecord) throws {
        try FileManager.default.trashItem(at: meeting.folder.url, resultingItemURL: nil)
        Log.write("Moved \(meeting.id) to the Trash")
        reload()
    }

    /// Moves the expired recordings and audio files to the Trash.
    func apply(_ actions: [RetentionAction]) -> (recordings: Int, audio: Int) {
        let fileManager = FileManager.default
        var result = (recordings: 0, audio: 0)
        for action in actions {
            switch action {
            case .trashRecording(let id):
                if (try? fileManager.trashItem(at: MeetingFolder.root.appendingPathComponent(id), resultingItemURL: nil))
                    != nil
                {
                    result.recordings += 1
                }
            case .trashAudio(let id):
                let folder = MeetingFolder(url: MeetingFolder.root.appendingPathComponent(id))
                let moved = [folder.micURL, folder.systemURL]
                    .filter { fileManager.fileExists(atPath: $0.path) }
                    .filter { (try? fileManager.trashItem(at: $0, resultingItemURL: nil)) != nil }
                if !moved.isEmpty { result.audio += 1 }
            }
        }
        if !actions.isEmpty { reload() }
        return result
    }

    /// An empty title removes the title, and the dashboard shows the date again.
    func rename(_ id: MeetingRecord.ID, to title: String) {
        update(id) { $0.title = title }
    }

    /// Adds the comma-separated tags in `text`. A tag that is already in use keeps its letter case.
    func addTags(_ text: String, to id: MeetingRecord.ID) {
        let known = allTags
        let tags = MeetingInfo.normalizedTags(text.components(separatedBy: ",")).map { tag in
            known.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        }
        update(id) { $0.tags += tags }
    }

    func removeTag(_ tag: String, from id: MeetingRecord.ID) {
        update(id) { $0.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    func setTag(_ tag: String, _ isOn: Bool, for id: MeetingRecord.ID) {
        if isOn { addTags(tag, to: id) } else { removeTag(tag, from: id) }
    }

    /// Gives every line of `speaker` the name `name`. If `name` is already a speaker, the two become one.
    func renameSpeaker(_ speaker: String, to name: String, in id: MeetingRecord.ID) {
        guard let name = SpeakerLabels.cleaned(name) else { return }
        updateTranscript(id) { SpeakerLabels.renaming(speaker, to: name, in: $0) }
    }

    /// Gives only the line at `index` the speaker `name`.
    func setSpeaker(_ name: String, ofLine index: Int, in id: MeetingRecord.ID) {
        guard let name = SpeakerLabels.cleaned(name) else { return }
        updateTranscript(id) { SpeakerLabels.relabeling(line: index, to: name, in: $0) }
    }

    /// Gives only the line at `index` the text `text`. An empty text changes nothing.
    func setText(_ text: String, ofLine index: Int, in id: MeetingRecord.ID) {
        guard let text = LineText.cleaned(text) else { return }
        updateTranscript(id) { LineText.replacing(line: index, with: text, in: $0) }
    }

    /// Writes the changed lines to transcript.txt, so that Copy and the MCP server get them too.
    /// meeting.json notes the change, so that Transcribe Again can warn before it replaces the lines.
    private func updateTranscript(_ id: MeetingRecord.ID, _ change: ([TranscriptLine]) -> [TranscriptLine]) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let lines = change(meeting.lines)
        guard lines != meeting.lines else { return }
        do {
            try TranscriptMerger.render(lines)
                .write(to: meeting.folder.transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            Log.write("Saving transcript.txt for \(id) failed: \(error)")
        }
        update(id) { $0.linesEdited = true }
    }

    private func update(_ id: MeetingRecord.ID, _ change: (inout MeetingInfo) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let folder = meetings[index].folder
        var info = MeetingInfo.load(from: folder.infoURL)
        change(&info)
        do {
            try info.save(to: folder.infoURL)
        } catch {
            Log.write("Saving meeting.json for \(id) failed: \(error)")
        }
        meetings[index] = MeetingRecord.load(folder)
    }
}

/// Plays the mic and system tracks of one meeting together, on the session clock.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var meetingID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var tracks: [(player: AVAudioPlayer, offset: TimeInterval)] = []
    private var ticker: Timer?

    func toggle(_ meeting: MeetingRecord) {
        if isPlaying && meetingID == meeting.id {
            pause()
        } else {
            play(meeting, from: meetingID == meeting.id ? currentTime : 0)
        }
    }

    func play(_ meeting: MeetingRecord, from time: TimeInterval) {
        if meetingID != meeting.id { load(meeting) }
        guard let clock = tracks.first?.player else { return }
        let start = max(0, min(time, duration))
        // Start all tracks at the same device time. A track that starts later on the
        // session clock waits for its offset.
        let startAt = clock.deviceCurrentTime + 0.05
        for (player, offset) in tracks {
            let local = start - offset
            player.currentTime = max(0, local)
            player.play(atTime: startAt + max(0, -local))
        }
        currentTime = start
        isPlaying = true
        startTicker()
    }

    func seek(_ meeting: MeetingRecord, to time: TimeInterval) {
        if isPlaying && meetingID == meeting.id {
            play(meeting, from: time)
        } else {
            if meetingID != meeting.id { load(meeting) }
            currentTime = time
        }
    }

    func pause() {
        tracks.forEach { $0.player.pause() }
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func stop() {
        pause()
        tracks = []
        meetingID = nil
        currentTime = 0
        duration = 0
    }

    private func load(_ meeting: MeetingRecord) {
        stop()
        let candidates = [
            (meeting.folder.micURL, meeting.session?.micOffset ?? 0),
            (meeting.folder.systemURL, meeting.session?.systemOffset ?? 0),
        ]
        tracks = candidates.compactMap { url, offset in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.prepareToPlay()
            return (player, offset)
        }
        duration = tracks.map { $0.player.duration + $0.offset }.max() ?? 0
        meetingID = meeting.id
    }

    private func startTicker() {
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        guard tracks.contains(where: { $0.player.isPlaying }) else {
            pause()
            currentTime = 0
            return
        }
        if let longest = tracks.max(by: { $0.player.duration + $0.offset < $1.player.duration + $1.offset }) {
            currentTime = longest.player.currentTime + longest.offset
        }
    }
}
