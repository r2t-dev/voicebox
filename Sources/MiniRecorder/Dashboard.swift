import AppKit
import MiniRecorderCore
import SwiftUI

/// The window with all recordings and their transcripts, like the meeting list in Narada.
/// AppKit owns the window, so that a menu bar app does not open it at launch.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()

    private var window: NSWindow?
    private let player = MeetingPlayer()
    private let state = DashboardState()

    func show(controller: RecorderController) {
        controller.library.reload()
        if window == nil {
            let hosting = NSHostingController(
                rootView: DashboardView(
                    controller: controller, library: controller.library, player: player, state: state))
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "MiniRecorder"
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Dashboard")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        player.stop()
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

    func beginRename(_ meeting: MeetingRecord) {
        titleDraft = meeting.title ?? ""
        renamingMeeting = meeting.id
    }

    func beginNewTag(_ meeting: MeetingRecord) {
        tagDraft = ""
        taggingMeeting = meeting.id
    }

    /// A binding that is true while `id` is set, for the isPresented argument of a dialog.
    func isPresenting(_ id: ReferenceWritableKeyPath<DashboardState, MeetingRecord.ID?>) -> Binding<Bool> {
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
            ToolbarItem(placement: .primaryAction) {
                RecordButton(controller: controller)
            }
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
        .frame(minWidth: 760, minHeight: 440)
        .onAppear {
            if state.selection == nil { state.selection = library.meetings.first?.id }
        }
        .onChange(of: state.selection) { player.stop() }
        .onChange(of: controller.activeMeeting) {
            if let active = controller.activeMeeting { state.selection = active }
        }
        .onChange(of: library.allTags) {
            if let tag = state.tagFilter, !library.allTags.contains(tag) { state.tagFilter = nil }
        }
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
        case .meeting where !meeting.lines.isEmpty:
            let mine = meeting.lines.filter { $0.speaker == "Me" }.count
            parts.append("\(meeting.lines.count) lines (Me \(mine), Others \(meeting.lines.count - mine))")
        case .note where !meeting.lines.isEmpty:
            parts.append("\(meeting.lines.count) lines")
        case .voice:
            if let words = meeting.preview?.split(whereSeparator: \.isWhitespace).count { parts.append("\(words) words") }
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
                Button("Transcribe Again") { Task { await controller.retranscribe(meeting) } }
                    .disabled(controller.phase != .idle || !meeting.hasAudio || isActive)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let silentSystemNote {
                        Label(silentSystemNote, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(meeting.lines.enumerated()), id: \.offset) { index, line in
                        TranscriptRow(
                            line: line, isCurrent: index == currentLine,
                            onPlay: { player.play(meeting, from: line.start) },
                            onCopy: {
                                controller.copyToClipboard(
                                    TranscriptMerger.render([line]).trimmingCharacters(in: .newlines))
                            })
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
            .help(isLoaded && player.isPlaying ? "Pause" : "Play both tracks")
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

struct TranscriptRow: View {
    let line: TranscriptLine
    let isCurrent: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void

    private var speakerColor: Color {
        switch line.speaker {
        case "Me": return .blue
        case "Others": return .orange
        default: return .secondary
        }
    }

    // A click anywhere on the row plays from the line. Selectable text would take the click
    // for selection, so the text is not selectable, and the context menu copies the line.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TranscriptMerger.timestamp(line.start))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(line.speaker)
                .fontWeight(.semibold)
                .foregroundStyle(speakerColor)
                .frame(width: 56, alignment: .leading)
            Text(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isCurrent ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .modifier(LinkCursor())
        .help("Play from \(TranscriptMerger.timestamp(line.start))")
        .contextMenu {
            Button("Play from Here", action: onPlay)
            Button("Copy Line", action: onCopy)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play from here", onPlay)
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
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
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
