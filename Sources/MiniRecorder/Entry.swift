import Foundation
import MiniRecorderCore

/// `MiniRecorder --transcribe <meeting folder>` transcribes an existing meeting folder without UI.
/// Any other start runs the menu bar app. `--record-seconds <n>` makes the app record once on launch.
@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--transcribe") {
            guard index + 1 < arguments.count else {
                fputs("usage: MiniRecorder --transcribe <meeting folder>\n", stderr)
                exit(2)
            }
            transcribe(folderPath: arguments[index + 1])
        }
        MiniRecorderApp.main()
    }

    private static func transcribe(folderPath: String) -> Never {
        let folder = MeetingFolder(url: URL(fileURLWithPath: folderPath, isDirectory: true))
        Task {
            do {
                let transcriber = Transcriber(model: AppSettings.storedModel)
                let outcome = try await TranscriptionPipeline.run(folder: folder, transcriber: transcriber) {
                    fputs("\($0)\n", stderr)
                }
                for warning in outcome.warnings {
                    fputs("warning: \(warning)\n", stderr)
                }
                print(outcome.transcript, terminator: "")
                exit(0)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }
}
