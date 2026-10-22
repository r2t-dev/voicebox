import MiniRecorderCore
import SwiftUI

struct MiniRecorderApp: App {
    @StateObject private var controller = RecorderController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(phase: controller.phase, kind: controller.activeKind, elapsed: controller.elapsed)
        }
    }
}

struct MenuBarLabel: View {
    let phase: RecorderController.Phase
    let kind: RecordingKind?
    let elapsed: TimeInterval

    // The menu bar draws SF Symbols as one-color templates. A non-template image keeps the red.
    private static let recordingImages: [RecordingKind: NSImage] = Dictionary(
        uniqueKeysWithValues: RecordingKind.allCases.map { kind in
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image =
                NSImage(systemSymbolName: kind.recordingSymbol, accessibilityDescription: "Recording")?
                .withSymbolConfiguration(configuration) ?? NSImage()
            image.isTemplate = false
            return (kind, image)
        })

    var body: some View {
        switch phase {
        case .recording:
            HStack(spacing: 4) {
                Image(nsImage: Self.recordingImages[kind ?? .meeting] ?? NSImage())
                Text(clock(elapsed)).monospacedDigit()
            }
        case .transcribing:
            Image(systemName: "hourglass")
        case .idle:
            Image(systemName: "mic")
        }
    }
}

/// "mm:ss", or "h:mm:ss" from one hour on.
func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%02d:%02d", minutes, secs)
}

struct MenuContent: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        Text(controller.status)
        ForEach(controller.notes, id: \.self) { Text($0) }
        Divider()
        switch controller.phase {
        case .idle:
            Button("Record Meeting") { Task { await controller.start(.meeting) } }
            Button("Take Notes (Microphone Only)") { Task { await controller.start(.note) } }
            if controller.hasHotKey {
                Button("Start Voice Input") { Task { await controller.start(.voice) } }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
            } else {
                Button("Start Voice Input") { Task { await controller.start(.voice) } }
            }
        case .recording:
            Button(controller.activeKind == .voice ? "Stop Voice Input" : "Stop and Transcribe") {
                Task { await controller.stop() }
            }
        case .transcribing:
            Button("Transcribing…") {}.disabled(true)
        }
        Divider()
        Button("Open Dashboard") { DashboardWindow.shared.show(controller: controller) }
            .keyboardShortcut("d")
        Button("Copy Last Transcript") { controller.copyLastTranscript() }
            .disabled(controller.lastTranscript == nil)
        Button("Open Recordings Folder") { controller.openRecordingsFolder() }
        Button("Request Permissions") { Task { await controller.requestPermissions() } }
            .disabled(controller.phase != .idle)
        Divider()
        Button("Quit MiniRecorder") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
