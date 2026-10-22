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
    @Published var confirmingTrash = false
    /// The meeting whose Copy button shows "Copied" for a moment.
    @Published var copiedMeeting: MeetingRecord.ID?
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
        guard !query.isEmpty else { return library.meetings }
        return library.meetings.filter { $0.transcript?.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleMeetings, selection: $state.selection) { meeting in
                MeetingRow(meeting: meeting, badge: badge(for: meeting))
            }
            .overlay {
                if visibleMeetings.isEmpty {
                    if state.query.isEmpty {
                        ContentUnavailableView(
                            "No Recordings", systemImage: "mic",
                            description: Text("Start a recording with the Record button or from the menu bar."))
                    } else {
                        ContentUnavailableView.search(text: state.query)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if let meeting = library.meetings.first(where: { $0.id == state.selection }) {
                MeetingDetail(
                    meeting: meeting, controller: controller, library: library, player: player, state: state)
            } else {
                ContentUnavailableView("Select a Recording", systemImage: "waveform")
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search transcripts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton(controller: controller)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear {
            if state.selection == nil { state.selection = library.meetings.first?.id }
        }
        .onChange(of: state.selection) { player.stop() }
        .onChange(of: controller.activeMeeting) {
            if let active = controller.activeMeeting { state.selection = active }
        }
    }

    private func badge(for meeting: MeetingRecord) -> MeetingBadge? {
        if controller.activeMeeting == meeting.id {
            return controller.phase == .recording ? .recording : .transcribing
        }
        guard meeting.transcript != nil else { return .noTranscript }
        return meeting.lines.isEmpty ? .noSpeech : nil
    }
}

struct MeetingRow: View {
    let meeting: MeetingRecord
    let badge: MeetingBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    meeting.startedAt.formatted(
                        .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                )
                .font(.headline)
                Spacer()
                if let duration = meeting.duration {
                    Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let badge {
                Text(badge.label).font(.callout).foregroundStyle(badge.color)
            } else if let first = meeting.lines.first {
                Text("\(first.speaker): \(first.text)")
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
        guard meeting.session?.systemPeak == 0 else { return nil }
        return "The system audio track is silent. If audio played, check the System Audio Recording permission."
    }

    private var summary: String {
        var parts: [String] = []
        if let duration = meeting.duration { parts.append(clock(duration)) }
        if !meeting.lines.isEmpty {
            let mine = meeting.lines.filter { $0.speaker == "Me" }.count
            parts.append("\(meeting.lines.count) lines (Me \(mine), Others \(meeting.lines.count - mine))")
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
        .confirmationDialog("Move this recording to the Trash?", isPresented: $state.confirmingTrash) {
            Button("Move to Trash", role: .destructive) {
                if isLoaded { player.stop() }
                do {
                    try library.moveToTrash(meeting)
                } catch {
                    Log.write("Move to Trash failed for \(meeting.id): \(error)")
                }
            }
        } message: {
            Text("The audio files and the transcript go to the Trash. You can put them back from there.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
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
                Button("Transcribe Again") { Task { await controller.retranscribe(meeting) } }
                    .disabled(controller.phase != .idle || !meeting.hasAudio)
                Divider()
                Button("Move to Trash…", role: .destructive) { state.confirmingTrash = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .disabled(isActive)
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
        } else if meeting.lines.isEmpty {
            ContentUnavailableView(
                "No Speech Found", systemImage: "waveform.slash",
                description: Text(silentSystemNote ?? "The speech model found no words in the audio."))
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

    // A click anywhere on the row plays from the line. Selectable text would take the click
    // for selection, so the text is not selectable, and the context menu copies the line.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TranscriptMerger.timestamp(line.start))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(line.speaker)
                .fontWeight(.semibold)
                .foregroundStyle(line.speaker == "Me" ? Color.blue : Color.orange)
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
            Button {
                Task { await controller.start() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .labelStyle(.titleAndIcon)
            .help("Start recording")
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
