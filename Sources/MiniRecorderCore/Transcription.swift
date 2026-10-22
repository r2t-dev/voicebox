import FluidAudio
import Foundation

public struct TrackTranscript: Sendable {
    public let text: String
    public let words: [TimedWord]
}

/// Parakeet TDT v3 through FluidAudio, on the Mac. Loads the model once and keeps it.
public actor Transcriber {
    private var manager: AsrManager?

    public init() {}

    /// Downloads the model from Hugging Face at first use, then compiles and loads it with Core ML.
    @discardableResult
    public func loadIfNeeded() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }

    public func transcribe(_ url: URL) async throws -> TrackTranscript {
        let manager = try await loadIfNeeded()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return TrackTranscript(text: result.text, words: words)
    }
}

public enum TranscriptionPipeline {
    public struct Outcome: Sendable {
        public let transcript: String
        public let lineCount: Int
        public let warnings: [String]
    }

    public enum Failure: LocalizedError {
        case nothingTranscribed([String])

        public var errorDescription: String? {
            switch self {
            case .nothingTranscribed(let reasons):
                return "No track could be transcribed. " + reasons.joined(separator: " ")
            }
        }
    }

    /// Writes transcript.txt for the kind in session.json. A meeting gets mic.caf as "Me" and
    /// system.caf as "Others". A note gets mic.caf as "Speaker". Voice input gets plain text.
    /// If one meeting track fails, the transcript holds the other track and the outcome lists a warning.
    public static func run(
        folder: MeetingFolder, transcriber: Transcriber, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        let session = try? SessionInfo.load(from: folder.sessionURL)
        let kind = session?.kind ?? .meeting
        if kind == .voice {
            return try await runVoice(folder: folder, transcriber: transcriber, progress: progress)
        }
        var tracks = [
            (name: "mic", speaker: kind == .meeting ? "Me" : "Speaker", audio: folder.micURL, text: folder.micTextURL,
             offset: session?.micOffset ?? 0, peak: session?.micPeak)
        ]
        if kind == .meeting {
            tracks.append(
                (name: "system", speaker: "Others", audio: folder.systemURL, text: folder.systemTextURL,
                 offset: session?.systemOffset ?? 0, peak: session?.systemPeak))
        }

        var linesPerTrack: [[TranscriptLine]] = []
        var warnings: [String] = []
        for track in tracks {
            guard FileManager.default.fileExists(atPath: track.audio.path) else {
                warnings.append("\(track.audio.lastPathComponent) is missing.")
                continue
            }
            if track.peak == 0 {
                warnings.append("The \(track.name) track is silent.")
                Log.write("Skipping silent \(track.name) track in \(folder.name)")
                continue
            }
            do {
                progress("Transcribing \(track.name) audio…")
                let started = Date()
                let result = try await transcriber.transcribe(track.audio)
                try result.text.write(to: track.text, atomically: true, encoding: .utf8)
                linesPerTrack.append(
                    TranscriptMerger.lines(
                        from: result.words, fallbackText: result.text, speaker: track.speaker, offset: track.offset))
                Log.write(
                    "Transcribed \(track.name) track of \(folder.name) in "
                        + String(format: "%.1f s: %d words", Date().timeIntervalSince(started), result.words.count))
            } catch {
                warnings.append("The \(track.name) track failed: \(error.localizedDescription)")
                Log.write("Transcription of \(track.name) track in \(folder.name) failed: \(error)")
            }
        }
        guard !linesPerTrack.isEmpty else { throw Failure.nothingTranscribed(warnings) }

        let lines = TranscriptMerger.merge(linesPerTrack)
        let transcript = TranscriptMerger.render(lines)
        try transcript.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        return Outcome(transcript: transcript, lineCount: lines.count, warnings: warnings)
    }

    private static func runVoice(
        folder: MeetingFolder, transcriber: Transcriber, progress: @Sendable (String) -> Void
    ) async throws -> Outcome {
        progress("Transcribing…")
        let result = try await transcriber.transcribe(folder.micURL)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try (text.isEmpty ? "" : text + "\n").write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        Log.write("Transcribed voice input \(folder.name): \(result.words.count) words")
        return Outcome(transcript: text, lineCount: text.isEmpty ? 0 : 1, warnings: [])
    }
}
