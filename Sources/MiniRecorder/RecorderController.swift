import AVFoundation
import AppKit
import Combine
import MiniRecorderCore

extension RecordingKind {
    var label: String {
        switch self {
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .voice: return "Voice"
        }
    }

    /// The menu bar symbol while this kind records.
    var recordingSymbol: String {
        switch self {
        case .meeting: return "record.circle.fill"
        case .note: return "note.text"
        case .voice: return "mic.fill"
        }
    }

    /// The symbol in the list of recordings.
    var listSymbol: String {
        switch self {
        case .meeting: return "person.2"
        case .note: return "note.text"
        case .voice: return "mic"
        }
    }
}

@MainActor
final class RecorderController: ObservableObject {
    enum Phase {
        case idle, recording, transcribing
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "Ready"
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastTranscript: String?
    @Published private(set) var elapsed: TimeInterval = 0
    /// The folder name of the recording that records or transcribes now.
    @Published private(set) var activeMeeting: String?
    @Published private(set) var activeKind: RecordingKind?
    /// Why macOS refused a shortcut, for the settings window.
    @Published private(set) var shortcutErrors: [HotKeyAction: String] = [:]
    /// From 0 to 1 while the settings window downloads a model.
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var modelDownloadError: String?

    let library = MeetingLibrary()
    let settings = AppSettings.shared

    private let transcriber = Transcriber(model: AppSettings.shared.model)
    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var folder: MeetingFolder?
    private var startedAt = Date()
    private var ticker: Timer?
    private var retentionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    private let hotKeys = HotKeyCenter()
    private var hotKeyPressedAt = Date.distantPast
    private var hotKeyStartedVoice = false
    /// The voice input shortcut came up while voice input was still starting.
    private var voiceHoldEnded = false

    init() {
        registerShortcuts(settings.shortcuts)
        // @Published sends the new value before it stores it, so use the value that it sends.
        settings.$shortcuts.dropFirst().sink { [weak self] in self?.registerShortcuts($0) }.store(in: &subscriptions)
        startRetention()

        if CommandLine.arguments.contains("--dashboard") {
            Task { DashboardWindow.shared.show(controller: self) }
        }
        if let tab = Self.argumentValue("--settings").flatMap(SettingsTab.init(rawValue:)) {
            Task { SettingsWindow.shared.show(controller: self, tab: tab) }
        }
        if let seconds = Self.argumentValue("--record-seconds").flatMap(Double.init) {
            let kind = Self.argumentValue("--record-kind").flatMap(RecordingKind.init(rawValue:)) ?? .meeting
            Task { await self.recordOnce(kind, seconds: seconds) }
        }
    }

    /// The shortcut of an action, if it is set and macOS accepted it.
    func shortcutDisplay(_ action: HotKeyAction) -> String? {
        guard shortcutErrors[action] == nil else { return nil }
        return settings.shortcuts[action]?.display
    }

    /// Turns the global shortcuts off while the settings window records a new shortcut.
    func pauseShortcuts() {
        hotKeys.unregisterAll()
    }

    func resumeShortcuts() {
        registerShortcuts(settings.shortcuts)
    }

    /// Moves the recordings and audio that the retention settings expire to the Trash.
    /// Returns the number of recordings and the number of audio sets that it moved.
    @discardableResult
    func cleanUp() -> (recordings: Int, audio: Int) {
        library.reload()
        let actions = settings.retention.actions(for: library.meetings, excluding: activeMeeting)
        let result = library.apply(actions)
        if !actions.isEmpty {
            Log.write("Retention moved \(result.recordings) recordings and the audio of \(result.audio) to the Trash")
        }
        return result
    }

    /// Deletes a downloaded model that is not selected. It does nothing while a transcription runs.
    func removeModel(_ model: AsrModelChoice) async {
        guard model != settings.model, phase != .transcribing else { return }
        modelDownloadError = nil
        // The transcriber can still hold the model from an earlier selection. Let it go first.
        await transcriber.use(settings.model)
        do {
            try model.removeDownload()
            Log.write("Removed \(model.title) from the Mac")
        } catch {
            modelDownloadError = "Could not remove \(model.title): \(error.localizedDescription)"
            Log.write("Removing \(model.title) failed: \(error)")
        }
    }

    func downloadModel() async {
        let model = settings.model
        modelDownloadError = nil
        modelDownloadProgress = 0
        do {
            try await model.download { fraction in
                Task { @MainActor in self.modelDownloadProgress = fraction }
            }
            Log.write("Downloaded \(model.title)")
        } catch {
            modelDownloadError = error.localizedDescription
            Log.write("Download of \(model.title) failed: \(error)")
        }
        modelDownloadProgress = nil
    }

    func start(_ kind: RecordingKind) async {
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
            var system: SystemAudioRecorder?
            if kind == .meeting {
                system = SystemAudioRecorder()
                do {
                    try system?.start(writingTo: folder.systemURL)
                } catch {
                    mic.stop()
                    try? FileManager.default.removeItem(at: folder.url)
                    throw error
                }
            }
            self.folder = folder
            self.mic = mic
            self.system = system
            startedAt = Date()
            startTicker()
            phase = .recording
            activeKind = kind
            activeMeeting = folder.name
            switch kind {
            case .meeting:
                status = "Recording a meeting since " + startedAt.formatted(date: .omitted, time: .standard)
            case .note:
                status = "Taking notes since " + startedAt.formatted(date: .omitted, time: .standard)
            case .voice:
                status = "Listening…"
            }
            if kind != .voice { library.reload() }
            Log.write(
                "\(kind.label) recording started in \(folder.url.path). Mic format: \(describe(mic.format)). "
                    + "System format: \(describe(system?.format)). Own audio excluded: \(system?.excludesOwnAudio ?? false)")
        } catch {
            status = "Could not start recording"
            notes = [error.localizedDescription]
            Log.write("Start failed: \(error)")
            return
        }
        if kind == .voice && voiceHoldEnded {
            voiceHoldEnded = false
            await stop()
        }
    }

    func stop() async {
        guard phase == .recording, let folder, let mic, let kind = activeKind else { return }
        ticker?.invalidate()
        ticker = nil
        mic.stop()
        system?.stop()
        let session = SessionInfo(
            kind: kind, startedAt: startedAt, stoppedAt: Date(),
            mic: mic.stats.snapshot, system: system?.stats.snapshot ?? .init())
        self.mic = nil
        self.system = nil
        try? session.save(to: folder.sessionURL)
        Log.write(
            "\(kind.label) recording stopped. Mic peak \(session.micPeak), system peak \(session.systemPeak), "
                + "mic offset \(session.micOffset) s, system offset \(session.systemOffset) s")
        if kind == .voice {
            await finishVoiceInput(folder)
        } else {
            await transcribe(folder, kind: kind, copyResult: true)
        }
    }

    /// Runs the transcription again for a recording from the dashboard. It does not change the clipboard.
    func retranscribe(_ meeting: MeetingRecord) async {
        guard phase == .idle else { return }
        notes = []
        activeKind = meeting.kind
        await transcribe(meeting.folder, kind: meeting.kind, copyResult: false)
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
        if !CursorPaste.isAllowed {
            CursorPaste.requestPermission()
            notes.append("To paste voice input at the cursor, allow MiniRecorder in Accessibility.")
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

    private func registerShortcuts(_ shortcuts: [HotKeyAction: Shortcut]) {
        hotKeys.unregisterAll()
        var errors: [HotKeyAction: String] = [:]
        for (action, shortcut) in shortcuts {
            let handlers: HotKeyCenter.Handlers
            switch action {
            case .voiceInput:
                handlers = .init(onPress: { [weak self] in self?.hotKeyPressed() },
                                 onRelease: { [weak self] in self?.hotKeyReleased() })
            case .meeting:
                handlers = .init(onPress: { [weak self] in self?.toggleRecording(.meeting) }, onRelease: {})
            case .notes:
                handlers = .init(onPress: { [weak self] in self?.toggleRecording(.note) }, onRelease: {})
            case .dashboard:
                handlers = .init(
                    onPress: { [weak self] in if let self { DashboardWindow.shared.show(controller: self) } },
                    onRelease: {})
            }
            let status = hotKeys.register(action, shortcut, handlers: handlers)
            if status != noErr {
                errors[action] = HotKeyCenter.refusalMessage(status, for: shortcut)
                Log.write("Shortcut \(shortcut.display) for \(action.rawValue) failed: \(status)")
            }
        }
        shortcutErrors = errors
    }

    /// Starts a recording of `kind`, or stops it if it runs.
    private func toggleRecording(_ kind: RecordingKind) {
        if phase == .idle {
            Task { await start(kind) }
        } else if phase == .recording && activeKind == kind {
            Task { await stop() }
        }
    }

    // A press starts voice input. If the keys stay down, releasing them stops it (push to talk).
    // After a short tap, voice input stays on until the next press.
    private func hotKeyPressed() {
        hotKeyPressedAt = Date()
        voiceHoldEnded = false
        switch phase {
        case .idle:
            hotKeyStartedVoice = true
            Task { await start(.voice) }
        case .recording where activeKind == .voice:
            hotKeyStartedVoice = false
            Task { await stop() }
        default:
            hotKeyStartedVoice = false
            Log.write("Voice input hotkey ignored: a \(activeKind?.label.lowercased() ?? "transcription") is running")
        }
    }

    private func hotKeyReleased() {
        guard hotKeyStartedVoice, Date().timeIntervalSince(hotKeyPressedAt) >= 0.4 else {
            hotKeyStartedVoice = false
            return
        }
        hotKeyStartedVoice = false
        if phase == .recording && activeKind == .voice {
            Task { await stop() }
        } else {
            voiceHoldEnded = true
        }
    }

    /// Copies the text, pastes it at the cursor, and keeps it as a text entry without audio.
    /// The settings can turn off the paste and the entry.
    private func finishVoiceInput(_ folder: MeetingFolder) async {
        phase = .transcribing
        status = "Transcribing…"
        await transcriber.use(settings.model)
        do {
            let outcome = try await TranscriptionPipeline.run(folder: folder, transcriber: transcriber)
            try? FileManager.default.removeItem(at: folder.micURL)
            if outcome.transcript.isEmpty || !settings.keepVoiceEntries {
                try? FileManager.default.removeItem(at: folder.url)
            }
            if outcome.transcript.isEmpty {
                status = "No speech found"
            } else {
                copyToClipboard(outcome.transcript)
                lastTranscript = outcome.transcript
                if !settings.pasteVoiceInput {
                    status = "Copied voice input"
                } else if CursorPaste.isAllowed {
                    // Give the clipboard a moment before the other app reads it.
                    try? await Task.sleep(for: .milliseconds(50))
                    CursorPaste.sendPaste()
                    status = "Pasted and copied voice input"
                } else {
                    CursorPaste.requestPermission()
                    status = "Copied voice input"
                    notes = ["To paste at the cursor, allow MiniRecorder in System Settings > Privacy & Security > Accessibility."]
                }
            }
            Log.write("Voice input \(folder.name): \(outcome.transcript.count) characters, paste allowed: \(CursorPaste.isAllowed)")
        } catch {
            // Keep the audio, so that Transcribe Again in the dashboard can try once more.
            status = "Voice input failed"
            notes = [error.localizedDescription]
            Log.write("Voice input transcription failed: \(error)")
        }
        finishActiveRecording()
    }

    private func transcribe(_ folder: MeetingFolder, kind: RecordingKind, copyResult: Bool) async {
        phase = .transcribing
        activeMeeting = folder.name
        status = "Loading \(settings.model.title) (the first use downloads it)…"
        await transcriber.use(settings.model)
        do {
            let outcome = try await TranscriptionPipeline.run(folder: folder, transcriber: transcriber) { message in
                Task { @MainActor in self.status = message }
            }
            notes = ["Saved \(folder.name)/transcript.txt"] + outcome.warnings
            if outcome.lineCount == 0 {
                status = "No speech found"
            } else if copyResult && settings.copyTranscript {
                copyToClipboard(outcome.transcript)
                lastTranscript = outcome.transcript
                status = "Copied \(outcome.lineCount) lines to the clipboard"
            } else {
                status = "Transcribed \(outcome.lineCount) lines"
            }
            if kind == .meeting, (try? SessionInfo.load(from: folder.sessionURL))?.systemPeak == 0 {
                notes.append("System audio was silent. Check System Settings > Privacy & Security > Audio Recording.")
            }
            Log.write("Transcript saved: \(folder.transcriptURL.path), \(outcome.lineCount) lines")
            if kind != .voice && settings.playSound { NSSound(named: "Glass")?.play() }
        } catch {
            status = "Transcription failed"
            notes = [error.localizedDescription]
            Log.write("Transcription failed: \(error)")
        }
        finishActiveRecording()
    }

    private func finishActiveRecording() {
        phase = .idle
        activeMeeting = nil
        activeKind = nil
        folder = nil
        library.reload()
    }

    private func recordOnce(_ kind: RecordingKind, seconds: Double) async {
        Log.write("Recording a \(kind.label.lowercased()) once for \(seconds) s, started by --record-seconds")
        await start(kind)
        guard phase == .recording else { return }
        try? await Task.sleep(for: .seconds(seconds))
        await stop()
    }

    /// Runs the retention cleanup at launch and then once an hour.
    private func startRetention() {
        Task { cleanUp() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.cleanUp() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
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
