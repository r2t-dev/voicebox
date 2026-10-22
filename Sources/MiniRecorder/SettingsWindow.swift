import AppKit
import Carbon.HIToolbox
import MiniRecorderCore
import SwiftUI

/// The settings window. AppKit owns it for the same reason as the dashboard window.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private let state = SettingsState()

    func show(controller: RecorderController, tab: SettingsTab? = nil) {
        state.controller = controller
        if let tab { state.tab = tab }
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    controller: controller, settings: controller.settings, library: controller.library, state: state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MiniRecorder Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Settings")
            self.window = window
        }
        state.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.stopRecordingShortcut()
    }
}

enum SettingsTab: String, Hashable {
    case general, shortcuts, retention, model
}

/// The view state of the settings window, outside @State for the reason in DashboardState.
@MainActor
final class SettingsState: ObservableObject {
    @Published var tab = SettingsTab.general
    /// The action whose shortcut field waits for keys.
    @Published var recordingAction: HotKeyAction?
    @Published var shortcutMessage: String?
    @Published var cleanupMessage: String?
    @Published var accessibilityAllowed = CursorPaste.isAllowed
    @Published var storageSize = "…"

    weak var controller: RecorderController?
    private var keyMonitor: Any?

    func refresh() {
        accessibilityAllowed = CursorPaste.isAllowed
        controller?.library.reload()
        cleanupMessage = nil
        Task {
            let bytes = await Task.detached { Self.folderSize(MeetingFolder.root) }.value
            storageSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    func startRecording(_ action: HotKeyAction) {
        stopRecordingShortcut()
        recordingAction = action
        shortcutMessage = nil
        // The registered shortcuts would catch the keys before this window sees them.
        controller?.pauseShortcuts()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if recordingAction != nil {
            recordingAction = nil
            controller?.resumeShortcuts()
        }
    }

    private func record(_ event: NSEvent) {
        guard let action = recordingAction, let settings = controller?.settings else { return }
        let shortcut = Shortcut(event: event)
        if shortcut.keyCode == kVK_Escape && shortcut.modifiers == 0 {
            stopRecordingShortcut()
            return
        }
        guard shortcut.isUsable else {
            shortcutMessage = "Use at least one of Control, Option or Command, or a function key."
            return
        }
        if let other = settings.shortcuts.first(where: { $0.key != action && $0.value == shortcut }) {
            shortcutMessage = "\(shortcut.display) is already the shortcut for “\(other.key.title)”."
            return
        }
        settings.shortcuts[action] = shortcut
        stopRecordingShortcut()
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        guard
            let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: .skipsHiddenFiles)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

struct SettingsView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var state: SettingsState

    var body: some View {
        TabView(selection: $state.tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            retention.tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }.tag(SettingsTab.retention)
            model.tabItem { Label("Model", systemImage: "waveform") }.tag(SettingsTab.model)
        }
        .padding()
        .frame(width: 600, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.accessibilityAllowed = CursorPaste.isAllowed
        }
        .onChange(of: state.tab) { state.stopRecordingShortcut() }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Meetings and notes") {
                Toggle("Copy the transcript to the clipboard", isOn: $settings.copyTranscript)
                Toggle("Play a sound when the transcript is ready", isOn: $settings.playSound)
            }
            Section {
                Toggle("Paste the text at the cursor", isOn: $settings.pasteVoiceInput)
                if settings.pasteVoiceInput {
                    LabeledContent("Accessibility permission") {
                        if state.accessibilityAllowed {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open Accessibility Settings") { CursorPaste.openAccessibilitySettings() }
                        }
                    }
                }
                Toggle("Keep voice entries in the dashboard", isOn: $settings.keepVoiceEntries)
            } header: {
                Text("Voice input")
            } footer: {
                Text("The text always goes to the clipboard. After a rebuild of the app, turn MiniRecorder off and on again in the Accessibility settings.")
            }
            Section("Storage") {
                LabeledContent("Recordings folder") {
                    HStack {
                        Text(MeetingFolder.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") { controller.openRecordingsFolder() }
                    }
                }
                LabeledContent("Space used", value: state.storageSize)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        VStack(alignment: .trailing, spacing: 2) {
                            shortcutField(action)
                            if let error = controller.shortcutErrors[action] {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    state.shortcutMessage
                        ?? "Click a field, then press the new shortcut. Press Escape to cancel. The shortcuts work in every app. Hold the voice input shortcut to talk, or tap it to start and tap it again to stop."
                )
                .foregroundStyle(state.shortcutMessage == nil ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutField(_ action: HotKeyAction) -> some View {
        HStack(spacing: 4) {
            Button {
                if state.recordingAction == action {
                    state.stopRecordingShortcut()
                } else {
                    state.startRecording(action)
                }
            } label: {
                Text(state.recordingAction == action ? "Press keys…" : settings.shortcuts[action]?.display ?? "None")
                    .frame(minWidth: 110)
            }
            // An empty button keeps the fields in line when a field has no shortcut to remove.
            Button {
                settings.shortcuts[action] = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove the shortcut")
            .opacity(settings.shortcuts[action] == nil ? 0 : 1)
            .disabled(settings.shortcuts[action] == nil)
        }
    }

    // MARK: Retention

    private static let retentionChoices: [(days: Int?, label: String)] = [
        (nil, "Never"), (1, "After 1 day"), (7, "After 1 week"), (30, "After 1 month"),
        (90, "After 3 months"), (365, "After 1 year"),
    ]

    private var retention: some View {
        let actions = settings.retention.actions(for: library.meetings, excluding: controller.activeMeeting)
        let recordings = actions.filter { if case .trashRecording = $0 { return true } else { return false } }.count
        let audio = actions.count - recordings
        return Form {
            ForEach(RecordingKind.allCases, id: \.self) { kind in
                Section(kind.pluralLabel) {
                    retentionPicker(
                        kind == .voice ? "Delete entries" : "Delete recordings", kind: kind, rule: \.recordingDays)
                    if kind != .voice {
                        retentionPicker("Delete only the audio", kind: kind, rule: \.audioDays)
                    }
                }
            }
            Section {
                LabeledContent(
                    actions.isEmpty
                        ? "Nothing is past these limits."
                        : "Past these limits now: \(recordings) recordings, and the audio of \(audio) more."
                ) {
                    Button("Clean Up Now") {
                        let result = controller.cleanUp()
                        state.cleanupMessage =
                            "Moved \(result.recordings) recordings and the audio of \(result.audio) to the Trash."
                    }
                    .disabled(actions.isEmpty)
                }
                if let message = state.cleanupMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            } footer: {
                Text("MiniRecorder moves expired items to the Trash at launch and once an hour. If it deletes only the audio, the transcript stays. A recording without a transcript keeps its audio.")
            }
        }
        .formStyle(.grouped)
    }

    private func retentionPicker(
        _ title: String, kind: RecordingKind, rule: WritableKeyPath<RetentionRule, Int?>
    ) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { settings.retention[kind][keyPath: rule] },
                set: { settings.retention[kind][keyPath: rule] = $0 })
        ) {
            ForEach(Self.retentionChoices, id: \.label) { choice in
                Text(choice.label).tag(choice.days)
            }
        }
    }

    // MARK: Model

    private var model: some View {
        Form {
            Section {
                Picker("Speech model", selection: $settings.model) {
                    ForEach(AsrModelChoice.allCases, id: \.self) { choice in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(choice.title)
                                if choice.isDownloaded {
                                    Text("Downloaded").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(choice.isSupported ? choice.summary : choice.summary + " Needs macOS 15 or later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(choice)
                        .disabled(!choice.isSupported)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("The next transcription uses the selected model. Transcribe Again in the dashboard uses it too.")
            }
            Section {
                LabeledContent("\(settings.model.title)") {
                    if let progress = controller.modelDownloadProgress {
                        ProgressView(value: progress).frame(width: 160)
                    } else if settings.model.isDownloaded {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Download Now") { Task { await controller.downloadModel() } }
                    }
                }
                if let error = controller.modelDownloadError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Show Models Folder") {
                    let folder = settings.model.folderURL
                    if FileManager.default.fileExists(atPath: folder.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } else {
                        NSWorkspace.shared.open(folder.deletingLastPathComponent())
                    }
                }
            } footer: {
                Text("The models come from Hugging Face. A model that is not on the Mac downloads at its first use.")
            }
        }
        .formStyle(.grouped)
    }
}
