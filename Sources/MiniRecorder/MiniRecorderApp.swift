import MiniRecorderCore
import SwiftUI

struct MiniRecorderApp: App {
    @StateObject private var controller = RecorderController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(phase: controller.phase, elapsed: controller.elapsed)
        }
    }
}

struct MenuBarLabel: View {
    let phase: RecorderController.Phase
    let elapsed: TimeInterval

    // The menu bar draws SF Symbols as one-color templates. A non-template image keeps the red.
    private static let recordingImage: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image =
            NSImage(systemSymbolName: RecorderController.Phase.recording.symbolName, accessibilityDescription: "Recording")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    var body: some View {
        if phase == .recording {
            HStack(spacing: 4) {
                Image(nsImage: Self.recordingImage)
                Text(clock(elapsed)).monospacedDigit()
            }
        } else {
            Image(systemName: phase.symbolName)
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
            Button("Start Recording") { Task { await controller.start() } }
        case .recording:
            Button("Stop and Transcribe") { Task { await controller.stop() } }
        case .transcribing:
            Button("Transcribing…") {}.disabled(true)
        }
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
