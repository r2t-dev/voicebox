import AVFoundation
import AppKit
import MiniRecorderCore

@MainActor
final class RecorderController: ObservableObject {
    enum Phase {
        case idle, recording, transcribing

        var symbolName: String {
            switch self {
            case .idle: return "mic"
            case .recording: return "record.circle.fill"
            case .transcribing: return "hourglass"
            }
        }
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "Ready"
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastTranscript: String?
    @Published private(set) var elapsed: TimeInterval = 0
    /// The folder name of the meeting that is being recorded or transcribed.
    @Published private(set) var activeMeeting: String?

    let library = MeetingLibrary()

    private let transcriber = Transcriber()
    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var folder: MeetingFolder?
    private var startedAt = Date()
    private var ticker: Timer?

    init() {
        if CommandLine.arguments.contains("--dashboard") {
            Task { DashboardWindow.shared.show(controller: self) }
        }
        if let seconds = Self.argumentValue("--record-seconds").flatMap(Double.init) {
            Task { await self.recordOnce(seconds: seconds) }
        }
    }

    func start() async {
        guard phase == .idle else { return }
        notes = []
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = "Microphone access is off"
            notes = ["Turn it on in System Settings > Privacy & Security > Microphone."]
            Log.write("Start refused: no microphone access")
            return
        }
        do {
            let folder = try MeetingFolder.create()
            let mic = MicRecorder()
            // Start the mic first. A Bluetooth headset then switches to call mode
            // before the system tap reads the output rate.
            try mic.start(writingTo: folder.micURL)
            let system = SystemAudioRecorder()
            do {
                try system.start(writingTo: folder.systemURL)
            } catch {
                mic.stop()
                throw error
            }
            self.folder = folder
            self.mic = mic
            self.system = system
            startedAt = Date()
            startTicker()
            phase = .recording
            activeMeeting = folder.name
            status = "Recording since " + startedAt.formatted(date: .omitted, time: .standard)
            library.reload()
            Log.write(
                "Recording started in \(folder.url.path). Mic format: \(describe(mic.format)). "
                    + "System format: \(describe(system.format)). Own audio excluded: \(system.excludesOwnAudio)")
        } catch {
            status = "Could not start recording"
            notes = [error.localizedDescription]
            Log.write("Start failed: \(error)")
        }
    }

    func stop() async {
        guard phase == .recording, let folder, let mic, let system else { return }
        ticker?.invalidate()
        ticker = nil
        mic.stop()
        system.stop()
        self.mic = nil
        self.system = nil
        let session = SessionInfo(
            startedAt: startedAt, stoppedAt: Date(), mic: mic.stats.snapshot, system: system.stats.snapshot)
        try? session.save(to: folder.sessionURL)
        Log.write(
            "Recording stopped. Mic peak \(session.micPeak), system peak \(session.systemPeak), "
                + "mic offset \(session.micOffset) s, system offset \(session.systemOffset) s")
        await transcribe(folder, copyResult: true)
    }

    /// Runs the transcription again for a meeting from the dashboard. It does not change the clipboard.
    func retranscribe(_ meeting: MeetingRecord) async {
        guard phase == .idle else { return }
        notes = []
        await transcribe(meeting.folder, copyResult: false)
    }

    func requestPermissions() async {
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        do {
            try await SystemAudioRecorder.warmUp()
            status = micAllowed ? "Microphone allowed" : "Microphone access is off"
            notes = ["If macOS asks for system audio access, click Allow."]
        } catch {
            status = "System audio tap failed"
            notes = [error.localizedDescription]
        }
        Log.write("Permission request: microphone \(micAllowed ? "allowed" : "denied"). \(notes.joined(separator: " "))")
    }

    func copyLastTranscript() {
        if let lastTranscript { copyToClipboard(lastTranscript) }
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: MeetingFolder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingFolder.root)
    }

    private func transcribe(_ folder: MeetingFolder, copyResult: Bool) async {
        phase = .transcribing
        activeMeeting = folder.name
        status = "Loading the speech model (the first run downloads it)…"
        do {
            let outcome = try await TranscriptionPipeline.run(folder: folder, transcriber: transcriber) { message in
                Task { @MainActor in self.status = message }
            }
            notes = ["Saved \(folder.name)/transcript.txt"] + outcome.warnings
            if outcome.lineCount == 0 {
                status = "No speech found"
            } else if copyResult {
                copyToClipboard(outcome.transcript)
                lastTranscript = outcome.transcript
                status = "Copied \(outcome.lineCount) lines to the clipboard"
            } else {
                status = "Transcribed \(outcome.lineCount) lines"
            }
            if (try? SessionInfo.load(from: folder.sessionURL))?.systemPeak == 0 {
                notes.append("System audio was silent. Check System Settings > Privacy & Security > Audio Recording.")
            }
            Log.write("Transcript saved: \(folder.transcriptURL.path), \(outcome.lineCount) lines")
            NSSound(named: "Glass")?.play()
        } catch {
            status = "Transcription failed"
            notes = [error.localizedDescription]
            Log.write("Transcription failed: \(error)")
        }
        phase = .idle
        activeMeeting = nil
        library.reload()
    }

    private func recordOnce(seconds: Double) async {
        Log.write("Recording once for \(seconds) s, started by --record-seconds")
        await start()
        guard phase == .recording else { return }
        try? await Task.sleep(for: .seconds(seconds))
        await stop()
    }

    private func startTicker() {
        elapsed = 0
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
        // The common run loop modes keep the timer running while the menu is open.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "none" }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, interleaved \(format.isInterleaved)"
    }

    private static func argumentValue(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
