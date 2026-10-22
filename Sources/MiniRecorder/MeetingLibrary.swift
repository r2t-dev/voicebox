import AVFoundation
import MiniRecorderCore

/// The meetings in ~/MiniRecorder, for the dashboard.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    func reload() {
        meetings = MeetingRecord.loadAll()
    }

    func moveToTrash(_ meeting: MeetingRecord) throws {
        try FileManager.default.trashItem(at: meeting.folder.url, resultingItemURL: nil)
        Log.write("Moved \(meeting.id) to the Trash")
        reload()
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
