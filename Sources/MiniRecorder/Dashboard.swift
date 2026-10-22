import AppKit
import MiniRecorderCore
import SwiftUI
import UniformTypeIdentifiers

/// The window with all recordings and their transcripts, like the meeting list in Narada.
/// AppKit owns the window, so that a menu bar app does not open it at launch.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()

    private var window: NSWindow?
    private var controller: RecorderController?
    private let player = MeetingPlayer()
    private let state = DashboardState()

    func show(controller: RecorderController) {
        self.controller = controller
        controller.library.reload()
        if window == nil {
            let hosting = NSHostingController(
                rootView: DashboardView(
                    controller: controller, library: controller.library, player: player, state: state))
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Voicebox"
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Dashboard")
            self.window = window
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.playOrPause(on: event) == true }
                return handled ? nil : event
            }
        }
        if let window { DockPresence.windowOpened(window) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        player.stop()
        if let window { DockPresence.windowClosed(window) }
    }

    /// Space plays or pauses the selected recording, like the play button. Space keeps its usual
    /// action while the user types, while a dialog is open, and on a focused control other than
    /// the recording list. Returns true if Space played or paused.
    private func playOrPause(on event: NSEvent) -> Bool {
        let spaceKey: UInt16 = 49
        guard event.keyCode == spaceKey, !event.isARepeat,
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            let window, event.window === window, window.attachedSheet == nil
        else { return false }
        let responder = window.firstResponder
        if responder is NSText { return false }
        if let control = responder as? NSControl, !(control is NSTableView) { return false }
        guard let controller, let id = state.selection, controller.activeMeeting != id,
            let meeting = controller.library.meetings.first(where: { $0.id == id }), meeting.hasAudio
        else { return false }
        player.toggle(meeting)
        return true
    }
}

/// The view state of the dashboard. It is not in @State, because @State is a macro in this SDK,
/// and the Command Line Tools have no plugin for the SwiftUI macros.
@MainActor
final class DashboardState: ObservableObject {
    @Published var selection: MeetingRecord.ID?
    @Published var query = ""
    @Published var tagFilter: String?
    @Published var kindFilter: RecordingKind?
    /// The meeting whose Copy button shows "Copied" for a moment.
    @Published var copiedMeeting: MeetingRecord.ID?
    /// The meetings that the open dialogs act on, and the text in their fields.
    @Published var trashingMeeting: MeetingRecord.ID?
    @Published var renamingMeeting: MeetingRecord.ID?
    @Published var titleDraft = ""
    @Published var taggingMeeting: MeetingRecord.ID?
    @Published var tagDraft = ""
    @Published var choosingAudioFile = false
    @Published var speakerDialog: SpeakerDialog?
    @Published var speakerDraft = ""
    /// The line whose text is in edit, and the text in its field.
    @Published var editingLine: LineEdit?
    @Published var lineDraft = ""
    /// The custom vocabulary sheet is open, the rows of its table, and the selected rows.
    @Published var editingVocabulary = false
    @Published var vocabularyRows: [VocabularyRow] = []
    @Published var selectedVocabularyRows = Set<VocabularyRow.ID>()
    /// The recording whose changed lines Transcribe Again asks about.
    @Published var confirmingTranscribeAgain: MeetingRecord.ID?
    /// The recording that the vocabulary sheet transcribes again after it closes.
    var transcribeAfterVocabulary: MeetingRecord.ID?

    /// One term of the vocabulary table, with its aliases as the user types them.
    struct VocabularyRow: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var aliases: String
    }

    struct LineEdit: Equatable {
        let meeting: MeetingRecord.ID
        let line: Int
    }

    /// Saves the line that is in edit, if there is one, and starts to edit another line.
    func beginLineEdit(_ line: Int, in meeting: MeetingRecord, library: MeetingLibrary) {
        endLineEdit(saving: true, in: library)
        lineDraft = meeting.lines[line].text
        editingLine = LineEdit(meeting: meeting.id, line: line)
    }

    /// Ends the edit. With `saving`, the line gets the text of the field.
    func endLineEdit(saving: Bool, in library: MeetingLibrary) {
        guard let edit = editingLine else { return }
        editingLine = nil
        if saving { library.setText(lineDraft, ofLine: edit.line, in: edit.meeting) }
    }

    /// Renames one speaker in every line, or, without `speaker`, gives one line a new speaker.
    struct SpeakerDialog {
        let meeting: MeetingRecord.ID
        let speaker: String?
        let line: Int
    }

    func beginRenameSpeaker(_ speaker: String, in meeting: MeetingRecord) {
        speakerDraft = speaker
        speakerDialog = SpeakerDialog(meeting: meeting.id, speaker: speaker, line: 0)
    }

    func beginNewSpeaker(line: Int, in meeting: MeetingRecord) {
        speakerDraft = SpeakerLabels.unusedName(in: meeting.lines)
        speakerDialog = SpeakerDialog(meeting: meeting.id, speaker: nil, line: line)
    }

    func beginRename(_ meeting: MeetingRecord) {
        titleDraft = meeting.title ?? ""
        renamingMeeting = meeting.id
    }

    func beginNewTag(_ meeting: MeetingRecord) {
        tagDraft = ""
        taggingMeeting = meeting.id
    }

    func beginVocabulary(_ vocabulary: [VocabularyTerm]) {
        vocabularyRows = vocabulary.map { VocabularyRow(text: $0.text, aliases: $0.aliasList) }
        selectedVocabularyRows = []
        editingVocabulary = true
    }

    /// Adds an empty row at the end and selects it. Returns its id.
    func addVocabularyRow() -> VocabularyRow.ID {
        let row = VocabularyRow(text: "", aliases: "")
        vocabularyRows.append(row)
        selectedVocabularyRows = [row.id]
        return row.id
    }

    func removeSelectedVocabularyRows() {
        vocabularyRows.removeAll { selectedVocabularyRows.contains($0.id) }
        selectedVocabularyRows = []
    }

    /// The vocabulary that the rows give, for the settings.
    var vocabularyFromRows: [VocabularyTerm] {
        VocabularyTerm.terms(fromRows: vocabularyRows.map { (text: $0.text, aliases: $0.aliases) })
    }

    /// Transcribes the recording again. The new transcript replaces the lines, so a line edit ends without saving.
    /// If the user changed the lines, it asks first, unless `confirmed`.
    func transcribeAgain(_ meeting: MeetingRecord, with controller: RecorderController, confirmed: Bool = false) {
        guard confirmed || !meeting.linesEdited else {
            confirmingTranscribeAgain = meeting.id
            return
        }
        editingLine = nil
        Task { await controller.retranscribe(meeting) }
    }

    /// A binding that is true while `id` is set, for the isPresented argument of a dialog.
    func isPresenting<Value>(_ id: ReferenceWritableKeyPath<DashboardState, Value?>) -> Binding<Bool> {
        Binding(
            get: { self[keyPath: id] != nil },
            set: { if !$0 { self[keyPath: id] = nil } })
    }
}

extension RecordingKind {
    var filterLabel: String {
        switch self {
        case .meeting: return "Meetings"
        case .note: return "Notes"
        case .voice: return "Voice"
        }
    }

    var pluralLabel: String {
        self == .voice ? "Voice Inputs" : filterLabel
    }
}

extension MeetingRecord {
    var shortDate: String {
        startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    var longDate: String { startedAt.formatted(date: .complete, time: .shortened) }
}

enum MeetingBadge {
    case recording, transcribing, noTranscript, noSpeech

    var label: String {
        switch self {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .noTranscript: return "No transcript"
        case .noSpeech: return "No speech found"
        }
    }

    var color: Color {
        switch self {
        case .recording: return .red
        case .transcribing: return .orange
        case .noTranscript, .noSpeech: return .secondary
        }
    }
}

struct DashboardView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var state: DashboardState

    private var visibleMeetings: [MeetingRecord] {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        return library.meetings.filter { meeting in
            if let kind = state.kindFilter, meeting.kind != kind { return false }
            if let tag = state.tagFilter, !meeting.hasTag(tag) { return false }
            guard !query.isEmpty else { return true }
            return [meeting.title, meeting.transcript].contains { $0?.localizedCaseInsensitiveContains(query) == true }
                || meeting.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            // The tabs sit in a stack above the list. As a safe-area inset of the list, they
            // scrolled under the toolbar like the list rows do.
            VStack(spacing: 0) {
                Picker("Show", selection: $state.kindFilter) {
                    Text("All").tag(RecordingKind?.none)
                    ForEach(RecordingKind.allCases, id: \.self) { Text($0.filterLabel).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                sidebarList
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let meeting = library.meetings.first(where: { $0.id == state.selection }) {
                MeetingDetail(
                    meeting: meeting, controller: controller, library: library, player: player, state: state)
            } else {
                ContentUnavailableView("Select a Recording", systemImage: "waveform")
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search titles, tags, transcripts")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $state.tagFilter) {
                        Text("All Recordings").tag(String?.none)
                        ForEach(library.allTags, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(state.tagFilter ?? "All Tags", systemImage: state.tagFilter == nil ? "tag" : "tag.fill")
                }
                .labelStyle(.titleAndIcon)
                .help("Show only the recordings with a tag")
                .disabled(library.allTags.isEmpty)
            }
            ToolbarItem {
                VocabularyButton(settings: controller.settings) {
                    state.beginVocabulary(controller.settings.vocabulary)
                }
            }
            ToolbarItem {
                Button {
                    state.choosingAudioFile = true
                } label: {
                    Label("Transcribe File", systemImage: "waveform.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .help("Choose an audio file. The app transcribes it into a new note.")
                .disabled(controller.phase != .idle)
            }
            ToolbarItem(placement: .primaryAction) {
                RecordButton(controller: controller)
            }
            ToolbarItem {
                Button {
                    SettingsWindow.shared.show(controller: controller)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        // Transcribe Again starts after the sheet closes, so that its warning can open.
        .sheet(isPresented: $state.editingVocabulary, onDismiss: transcribeAfterVocabulary) {
            let selected = library.meetings.first { $0.id == state.selection }
            VocabularySheet(
                settings: controller.settings, state: state,
                onTranscribeAgain: selected.flatMap { meeting in
                    controller.canRetranscribe(meeting) ? { state.transcribeAfterVocabulary = meeting.id } : nil
                })
        }
        .confirmationDialog(
            "Transcribe this recording again?", isPresented: state.isPresenting(\.confirmingTranscribeAgain),
            presenting: state.confirmingTranscribeAgain
        ) { id in
            Button("Transcribe Again", role: .destructive) {
                guard let meeting = library.meetings.first(where: { $0.id == id }) else { return }
                state.transcribeAgain(meeting, with: controller, confirmed: true)
            }
        } message: { _ in
            Text("The new transcript replaces the speaker names and the text changes that you made.")
        }
        .alert("New Tag", isPresented: state.isPresenting(\.taggingMeeting)) {
            TextField("Tag", text: $state.tagDraft)
            Button("Add") {
                if let id = state.taggingMeeting { library.addTags(state.tagDraft, to: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To add several tags, separate them with commas.")
        }
        .confirmationDialog("Move this recording to the Trash?", isPresented: state.isPresenting(\.trashingMeeting)) {
            Button("Move to Trash", role: .destructive) {
                guard let meeting = library.meetings.first(where: { $0.id == state.trashingMeeting }) else { return }
                if player.meetingID == meeting.id { player.stop() }
                do {
                    try library.moveToTrash(meeting)
                } catch {
                    Log.write("Move to Trash failed for \(meeting.id): \(error)")
                }
            }
        } message: {
            Text("The audio files and the transcript go to the Trash. You can put them back from there.")
        }
        .fileImporter(isPresented: $state.choosingAudioFile, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                Task { await controller.importNote(from: url) }
            case .failure(let error):
                Log.write("Choosing an audio file failed: \(error)")
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear {
            if state.selection == nil { state.selection = library.meetings.first?.id }
        }
        .onChange(of: state.selection) {
            state.endLineEdit(saving: true, in: library)
            player.stop()
        }
        .onChange(of: controller.activeMeeting) {
            if let active = controller.activeMeeting { state.selection = active }
        }
        .onChange(of: library.allTags) {
            if let tag = state.tagFilter, !library.allTags.contains(tag) { state.tagFilter = nil }
        }
    }

    private func transcribeAfterVocabulary() {
        guard let id = state.transcribeAfterVocabulary else { return }
        state.transcribeAfterVocabulary = nil
        guard let meeting = library.meetings.first(where: { $0.id == id }) else { return }
        state.transcribeAgain(meeting, with: controller)
    }

    private var sidebarList: some View {
        List(visibleMeetings, selection: $state.selection) { meeting in
            MeetingRow(meeting: meeting, badge: badge(for: meeting))
                .contextMenu { rowMenu(for: meeting) }
        }
        .overlay {
            if visibleMeetings.isEmpty {
                if !state.query.isEmpty {
                    ContentUnavailableView.search(text: state.query)
                } else if let tag = state.tagFilter {
                    ContentUnavailableView("No Recordings Tagged “\(tag)”", systemImage: "tag")
                } else if let kind = state.kindFilter {
                    ContentUnavailableView("No \(kind.pluralLabel)", systemImage: kind.listSymbol)
                } else {
                    ContentUnavailableView(
                        "No Recordings", systemImage: "mic",
                        description: Text("Start a recording with the Record button or from the menu bar."))
                }
            }
        }
        .alert("Rename Recording", isPresented: state.isPresenting(\.renamingMeeting)) {
            TextField("Title", text: $state.titleDraft)
            Button("Rename") {
                if let id = state.renamingMeeting { library.rename(id, to: state.titleDraft) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave the title empty to show the date instead.")
        }
    }

    @ViewBuilder
    private func rowMenu(for meeting: MeetingRecord) -> some View {
        Button("Rename…") { state.beginRename(meeting) }
        Menu("Tags") {
            ForEach(library.allTags, id: \.self) { tag in
                Toggle(
                    tag,
                    isOn: Binding(
                        get: { meeting.hasTag(tag) },
                        set: { library.setTag(tag, $0, for: meeting.id) }))
            }
            if !library.allTags.isEmpty { Divider() }
            Button("New Tag…") { state.beginNewTag(meeting) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { state.trashingMeeting = meeting.id }
            .disabled(controller.activeMeeting == meeting.id)
    }

    private func badge(for meeting: MeetingRecord) -> MeetingBadge? {
        if controller.activeMeeting == meeting.id {
            return controller.phase == .recording ? .recording : .transcribing
        }
        guard meeting.transcript != nil else { return .noTranscript }
        return meeting.hasNoSpeech ? .noSpeech : nil
    }
}

struct MeetingRow: View {
    let meeting: MeetingRecord
    let badge: MeetingBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: meeting.kind.listSymbol)
                    .foregroundStyle(.secondary)
                    .help(meeting.kind.label)
                Text(meeting.title ?? meeting.shortDate)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let duration = meeting.duration {
                    Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if meeting.title != nil {
                Text(meeting.shortDate).font(.caption).foregroundStyle(.secondary)
            }
            if !meeting.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(meeting.tags, id: \.self) { TagChip(tag: $0) }
                }
            }
            if let badge {
                Text(badge.label).font(.callout).foregroundStyle(badge.color)
            } else if let preview = meeting.preview {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

struct MeetingDetail: View {
    let meeting: MeetingRecord
    @ObservedObject var controller: RecorderController
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var state: DashboardState

    private var isActive: Bool { controller.activeMeeting == meeting.id }
    private var copied: Bool { state.copiedMeeting == meeting.id }
    private var isLoaded: Bool { player.meetingID == meeting.id }

    private var currentLine: Int? {
        guard isLoaded, player.isPlaying || player.currentTime > 0 else { return nil }
        return meeting.lines.lastIndex { $0.start <= player.currentTime }
    }

    private var silentSystemNote: String? {
        guard meeting.kind == .meeting, meeting.session?.systemPeak == 0 else { return nil }
        return "The system audio track is silent. If audio played, check the System Audio Recording permission."
    }

    private var summary: String {
        var parts: [String] = []
        if meeting.title != nil { parts.append(meeting.longDate) }
        if let duration = meeting.duration { parts.append(clock(duration)) }
        switch meeting.kind {
        case .meeting where !meeting.lines.isEmpty, .note where !meeting.lines.isEmpty:
            // The lines of each speaker, in the order in which the speakers first talk.
            let speakers = SpeakerLabels.speakers(in: meeting.lines)
            let each = speakers.map { speaker in
                "\(speaker) \(meeting.lines.filter { $0.speaker == speaker }.count)"
            }
            parts.append(
                counted(meeting.lines.count, "line") + (speakers.count > 1 ? " (\(each.joined(separator: ", ")))" : ""))
        case .voice:
            if let words = meeting.preview?.split(whereSeparator: \.isWhitespace).count { parts.append(counted(words, "word")) }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding()
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if meeting.hasAudio && !isActive {
                Divider()
                playerBar.padding(.horizontal).padding(.vertical, 10)
            }
        }
        .alert(
            state.speakerDialog?.speaker == nil ? "New Speaker" : "Rename Speaker",
            isPresented: state.isPresenting(\.speakerDialog), presenting: state.speakerDialog
        ) { dialog in
            TextField("Name", text: $state.speakerDraft)
            Button(dialog.speaker == nil ? "Change" : "Rename") {
                if let speaker = dialog.speaker {
                    library.renameSpeaker(speaker, to: state.speakerDraft, in: dialog.meeting)
                } else {
                    library.setSpeaker(state.speakerDraft, ofLine: dialog.line, in: dialog.meeting)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { dialog in
            if let speaker = dialog.speaker {
                Text(
                    "Every line of “\(speaker)” gets the new name. "
                        + "If another speaker has this name, the two become one.")
            } else {
                Text("Only this line gets the new speaker.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.title ?? meeting.longDate)
                        .font(.title2.weight(.semibold))
                        .onTapGesture(count: 2) { state.beginRename(meeting) }
                        .help("Double-click to rename")
                    Button {
                        state.beginRename(meeting)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename")
                }
                Text(summary).foregroundStyle(.secondary)
                tagBar
            }
            Spacer()
            Button {
                controller.copyToClipboard(meeting.transcript ?? "")
                state.copiedMeeting = meeting.id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if state.copiedMeeting == meeting.id { state.copiedMeeting = nil }
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(meeting.lines.isEmpty)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Menu {
                Button("Rename…") { state.beginRename(meeting) }
                Button("Transcribe Again") { state.transcribeAgain(meeting, with: controller) }
                    .disabled(!controller.canRetranscribe(meeting))
                Divider()
                Button("Move to Trash…", role: .destructive) { state.trashingMeeting = meeting.id }
                    .disabled(isActive)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
    }

    /// The tags of the meeting, and a menu that adds a tag that is in use or a new one.
    private var tagBar: some View {
        let unused = library.allTags.filter { !meeting.hasTag($0) }
        return FlowLayout(spacing: 6) {
            ForEach(meeting.tags, id: \.self) { tag in
                TagChip(
                    tag: tag,
                    onSelect: { state.tagFilter = tag },
                    onRemove: { library.removeTag(tag, from: meeting.id) })
            }
            Menu {
                ForEach(unused, id: \.self) { tag in
                    Button(tag) { library.addTags(tag, to: meeting.id) }
                }
                if !unused.isEmpty { Divider() }
                Button("New Tag…") { state.beginNewTag(meeting) }
            } label: {
                Label("Add Tag", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isActive {
            ContentUnavailableView {
                Label(
                    controller.phase == .recording ? "Recording" : "Transcribing",
                    systemImage: controller.phase == .recording ? "record.circle" : "hourglass")
            } description: {
                Text(controller.phase == .recording ? clock(controller.elapsed) : controller.status)
            }
        } else if meeting.transcript == nil {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "text.badge.xmark")
            } description: {
                Text("This recording has no transcript yet.")
            } actions: {
                Button("Transcribe") { Task { await controller.retranscribe(meeting) } }
                    .disabled(controller.phase != .idle || !meeting.hasAudio)
            }
        } else if meeting.hasNoSpeech {
            ContentUnavailableView(
                "No Speech Found", systemImage: "waveform.slash",
                description: Text(silentSystemNote ?? "The speech model found no words in the audio."))
        } else if meeting.kind == .voice {
            ScrollView {
                Text(meeting.preview ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            let speakers = SpeakerLabels.speakers(in: meeting.lines)
            let colors = TranscriptRow.colors(for: speakers)
            let labelWidth = TranscriptRow.labelWidth(for: speakers)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let silentSystemNote {
                        Label(silentSystemNote, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(meeting.lines.enumerated()), id: \.offset) { index, line in
                        TranscriptRow(
                            line: line, isCurrent: index == currentLine, speakers: speakers,
                            color: colors[line.speaker] ?? .secondary, labelWidth: labelWidth,
                            onSeek: { player.seek(meeting, to: line.start) },
                            onPlay: { player.play(meeting, from: line.start) },
                            onCopy: {
                                controller.copyToClipboard(
                                    TranscriptMerger.render([line]).trimmingCharacters(in: .newlines))
                            },
                            onSetSpeaker: { library.setSpeaker($0, ofLine: index, in: meeting.id) },
                            onNewSpeaker: { state.beginNewSpeaker(line: index, in: meeting) },
                            onRenameSpeaker: { state.beginRenameSpeaker(line.speaker, in: meeting) },
                            isEditing: state.editingLine == DashboardState.LineEdit(meeting: meeting.id, line: index),
                            draft: $state.lineDraft,
                            onEdit: { state.beginLineEdit(index, in: meeting, library: library) },
                            onEndEdit: { state.endLineEdit(saving: $0, in: library) })
                    }
                }
                .padding()
            }
        }
    }

    private var playerBar: some View {
        let total = isLoaded ? player.duration : (meeting.duration ?? 0)
        return HStack(spacing: 12) {
            Button {
                player.toggle(meeting)
            } label: {
                Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(isLoaded && player.isPlaying ? "Pause (Space)" : "Play both tracks (Space)")
            Text(clock(isLoaded ? player.currentTime : 0)).monospacedDigit().foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { isLoaded ? player.currentTime : 0 },
                    set: { player.seek(meeting, to: $0) }),
                in: 0...max(total, 0.1))
            Text(clock(total)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// The toolbar button that opens the custom vocabulary. The label shows the number of terms.
struct VocabularyButton: View {
    @ObservedObject var settings: AppSettings
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                settings.vocabulary.isEmpty ? "Vocabulary" : "Vocabulary (\(settings.vocabulary.count))",
                systemImage: "character.book.closed")
        }
        .labelStyle(.titleAndIcon)
        .help("Names and terms that all transcriptions spell as you write them")
    }
}

/// Edits the custom vocabulary in a table of terms and their aliases. The list is the same for all recordings
/// and for voice input.
struct VocabularySheet: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: DashboardState
    /// Saves the list and transcribes the selected recording again. Nil if the recording cannot.
    let onTranscribeAgain: (() -> Void)?
    @FocusState private var focusedRow: DashboardState.VocabularyRow.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Vocabulary").font(.headline)
            Text(
                "Names and terms that the speech model gets wrong. Aliases are the spellings that the model "
                    + "writes instead. Separate them with commas.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                table
                Divider()
                tableButtons
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Text(
                "The next transcriptions use the list. A second speech model compares each term with the audio. "
                    + "The first use downloads it, about 100 MB. It is an English model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let onTranscribeAgain {
                    Button("Save and Transcribe Again") {
                        save()
                        onTranscribeAgain()
                    }
                    .help("Transcribe Again replaces the speaker names and the text changes of this recording.")
                }
                Spacer()
                Button("Cancel", role: .cancel) { state.editingVocabulary = false }
                    .keyboardShortcut(.cancelAction)
                // Return ends the edit of a cell, so Save is Command-Return.
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private var table: some View {
        Table(state.vocabularyRows, selection: $state.selectedVocabularyRows) {
            TableColumn("Term") { row in
                TextField("Term", text: binding(row.id, \.text), prompt: Text("Term"))
                    .focused($focusedRow, equals: row.id)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Aliases") { row in
                // The hint shows only in a new row, so that it does not fill the column.
                TextField("Aliases", text: binding(row.id, \.aliases), prompt: row.text.isEmpty ? Text("Optional") : nil)
            }
        }
        .onDeleteCommand(perform: state.removeSelectedVocabularyRows)
        .overlay {
            if state.vocabularyRows.isEmpty {
                Text("No terms. To add one, click +.").foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
    }

    /// The + and − buttons under the table, like the lists in System Settings.
    private var tableButtons: some View {
        HStack(spacing: 0) {
            Button {
                let id = state.addVocabularyRow()
                // After the table shows the new row.
                DispatchQueue.main.async { focusedRow = id }
            } label: {
                Label("Add Term", systemImage: "plus").labelStyle(.iconOnly).frame(width: 24, height: 20)
            }
            .help("Add a term")
            Divider().frame(height: 16)
            Button(action: state.removeSelectedVocabularyRows) {
                Label("Remove Terms", systemImage: "minus").labelStyle(.iconOnly).frame(width: 24, height: 20)
            }
            .help("Remove the selected terms")
            .disabled(state.selectedVocabularyRows.isEmpty)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// A text of the row with `id`. The row can go away while its field still shows, so a missing row reads as
    /// empty and takes no text.
    private func binding(
        _ id: DashboardState.VocabularyRow.ID, _ keyPath: WritableKeyPath<DashboardState.VocabularyRow, String>
    ) -> Binding<String> {
        Binding(
            get: { state.vocabularyRows.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { text in
                guard let index = state.vocabularyRows.firstIndex(where: { $0.id == id }) else { return }
                state.vocabularyRows[index][keyPath: keyPath] = text
            })
    }

    private func save() {
        settings.vocabulary = state.vocabularyFromRows
        state.editingVocabulary = false
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let isCurrent: Bool
    /// All speakers of the transcript, for the Change Speaker menu.
    let speakers: [String]
    let color: Color
    let labelWidth: CGFloat
    /// Moves playback to the line. Audio that plays goes on from there, and paused audio stays paused.
    let onSeek: () -> Void
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onSetSpeaker: (String) -> Void
    let onNewSpeaker: () -> Void
    let onRenameSpeaker: () -> Void
    /// True while the text of the line is a field that the user can edit.
    let isEditing: Bool
    @Binding var draft: String
    let onEdit: () -> Void
    /// Ends the edit. True saves the text.
    let onEndEdit: (Bool) -> Void
    @FocusState private var editorFocused: Bool

    private static let speakerColors: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint]

    /// "Me" is blue. The other speakers get the colors in turn, in the order in which they first talk,
    /// so that a speaker keeps its color after a rename.
    static func colors(for speakers: [String]) -> [String: Color] {
        var colors = ["Me": Color.blue]
        for (index, speaker) in speakers.filter({ $0 != "Me" }).enumerated() {
            colors[speaker] = speakerColors[index % speakerColors.count]
        }
        return colors
    }

    /// The width of the longest name, from 56 to 160 points. A longer name ends in "…".
    static func labelWidth(for speakers: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let widest = speakers.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(160, max(56, ceil(widest) + 2))
    }

    // A click anywhere on the row moves playback to the line. Selectable text would take the click
    // for selection, so the text is not selectable, and the context menu copies the line.
    // Edit Text in the context menu turns the text into a field. Return saves, Escape cancels,
    // and a click outside the field saves.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TranscriptMerger.timestamp(line.start))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(line.speaker)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if isEditing {
                TextField("Text", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($editorFocused)
                    // After the context menu closes, so that the menu does not take the focus back.
                    .onAppear { DispatchQueue.main.async { editorFocused = true } }
                    .onSubmit { onEndEdit(true) }
                    .onExitCommand { onEndEdit(false) }
                    .onChange(of: editorFocused) { hadFocus, hasFocus in
                        if hadFocus && !hasFocus { onEndEdit(true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isCurrent ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { onSeek() } }
        .modifier(LinkCursor(isOn: !isEditing))
        .help(isEditing ? "" : "Go to \(TranscriptMerger.timestamp(line.start))")
        .contextMenu {
            Button("Play from Here", action: onPlay)
            Button("Copy Line", action: onCopy)
            Button("Edit Text", action: onEdit)
            Divider()
            Menu("Change Speaker") {
                ForEach(speakers, id: \.self) { speaker in
                    Toggle(
                        speaker,
                        isOn: Binding(
                            get: { speaker == line.speaker },
                            set: { if $0 { onSetSpeaker(speaker) } }))
                }
                Divider()
                Button("New Speaker…", action: onNewSpeaker)
            }
            Button("Rename “\(line.speaker)”…", action: onRenameSpeaker)
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Go to this line", onSeek)
        .accessibilityAction(named: "Play from here", onPlay)
        .accessibilityAction(named: "Edit text", onEdit)
        .accessibilityAction(named: "Rename speaker", onRenameSpeaker)
    }
}

struct TagChip: View {
    let tag: String
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .onTapGesture { onSelect?() }
                .help(onSelect == nil ? "" : "Show only the recordings with this tag")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove the tag")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

/// Places its views in rows and starts a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

/// The pointing-hand cursor over a clickable row.
struct LinkCursor: ViewModifier {
    /// False leaves the cursor alone, for example over a text field.
    var isOn = true

    func body(content: Content) -> some View {
        if !isOn {
            content
        } else if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

struct RecordButton: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        switch controller.phase {
        case .idle:
            Menu {
                Button("Record Meeting") { Task { await controller.start(.meeting) } }
                Button("Take Notes (Microphone Only)") { Task { await controller.start(.note) } }
            } label: {
                Label("Record", systemImage: "record.circle")
            } primaryAction: {
                Task { await controller.start(.meeting) }
            }
            .labelStyle(.titleAndIcon)
            .help("Click to record a meeting. Open the menu to take notes with the microphone only.")
        case .recording:
            Button {
                Task { await controller.stop() }
            } label: {
                Label("Stop  \(clock(controller.elapsed))", systemImage: "stop.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.red)
            .help("Stop and transcribe")
        case .transcribing:
            ProgressView().controlSize(.small)
        }
    }
}
