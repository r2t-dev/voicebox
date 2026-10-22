import FluidAudio
import Foundation

public struct TrackTranscript: Sendable {
    public let text: String
    public let words: [TimedWord]
    /// The tokens of the speech model that the words come from, for the custom vocabulary.
    let tokenTimings: [TokenTiming]

    init(text: String, words: [TimedWord], tokenTimings: [TokenTiming] = []) {
        self.text = text
        self.words = words
        self.tokenTimings = tokenTimings
    }
}

/// The speech models that the settings offer. All run on the Mac through FluidAudio.
public enum AsrModelChoice: String, CaseIterable, Codable, Sendable {
    case v3, ultra, redux, v2, phonon2, tdtCtc110m, tdtJa

    public var title: String {
        switch self {
        case .v3: return "Parakeet TDT v3"
        case .ultra: return "Parakeet Ultra"
        case .redux: return "Parakeet Redux"
        case .v2: return "Parakeet TDT v2"
        case .phonon2: return "Phonon-2"
        case .tdtCtc110m: return "Parakeet TDT-CTC 110M"
        case .tdtJa: return "Parakeet TDT Japanese"
        }
    }

    public var summary: String {
        switch self {
        case .v3: return "25 European languages. The FluidAudio default."
        case .ultra: return "25 European languages. More accurate than v3 at the same speed."
        case .redux:
            return "25 European languages. The smallest download, about 220 MB. The first use compiles it for several minutes."
        case .v2: return "English only. The highest recall."
        case .phonon2: return "English only. Faster than v3."
        case .tdtCtc110m: return "English only. Small and fast, a little less accurate."
        case .tdtJa: return "Japanese only."
        }
    }

    /// Redux and Phonon-2 need macOS 15 or later.
    public var isSupported: Bool {
        switch self {
        case .redux, .phonon2:
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        default:
            return true
        }
    }

    public var isDownloaded: Bool {
        AsrModels.modelsExist(at: folderURL, version: version)
    }

    public var folderURL: URL { AsrModels.defaultCacheDirectory(for: version) }

    /// All folders that the model downloads. Parakeet TDT-CTC 110M also downloads a CTC head
    /// from a second repository, for custom vocabulary.
    public var folderURLs: [URL] {
        guard self == .tdtCtc110m else { return [folderURL] }
        return [folderURL, MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetCtc110m)]
    }

    /// The disk space of all folders of the model, in bytes.
    public var allocatedSize: Int64 {
        folderURLs.reduce(0) { $0 + MiniRecorderCore.allocatedSize(of: $1) }
    }

    var version: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .ultra: return .ultra
        case .redux: return .redux
        case .v2: return .v2
        case .phonon2: return .phonon2
        case .tdtCtc110m: return .tdtCtc110m
        case .tdtJa: return .tdtJa
        }
    }

    /// Downloads the model from Hugging Face without loading it. `progress` gets values from 0 to 1.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(version: version) { progress($0.fractionCompleted) }
    }

    /// Deletes the downloaded files of the model, to free disk space. A later use downloads it again.
    public func removeDownload() throws {
        // Each model folder is directly in FluidAudio/Models. Delete nothing else.
        let modelsFolder = MLModelConfigurationUtils.defaultModelsDirectory().standardizedFileURL
        for folder in folderURLs where FileManager.default.fileExists(atPath: folder.path) {
            guard folder.deletingLastPathComponent().standardizedFileURL == modelsFolder else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
            }
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// The disk space that the files in a folder use, in bytes.
public func allocatedSize(of folder: URL) -> Int64 {
    guard
        let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: .skipsHiddenFiles)
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in files {
        total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

/// A Parakeet model through FluidAudio, on the Mac. Loads the model once and keeps it.
/// It also finds the speakers in a track with the FluidAudio offline diarizer,
/// and puts the terms of the custom vocabulary into a transcript.
public actor Transcriber {
    private var manager: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var ctcModels: CtcModels?
    private var booster: VocabularyBooster?
    public private(set) var model: AsrModelChoice
    public private(set) var vocabulary: [VocabularyTerm]

    public init(model: AsrModelChoice = .v3, vocabulary: [VocabularyTerm] = []) {
        self.model = model
        self.vocabulary = vocabulary
    }

    /// The next transcription uses `model`. A change unloads the current model.
    public func use(_ model: AsrModelChoice) {
        guard model != self.model else { return }
        self.model = model
        manager = nil
    }

    /// The next transcription uses these terms. An empty list turns the custom vocabulary off.
    public func use(vocabulary: [VocabularyTerm]) {
        guard vocabulary != self.vocabulary else { return }
        self.vocabulary = vocabulary
        booster = nil
    }

    /// Downloads the model from Hugging Face at first use, then compiles and loads it with Core ML.
    @discardableResult
    public func loadIfNeeded() async throws -> AsrManager {
        if let manager { return manager }
        let requested = model
        let models = try await AsrModels.downloadAndLoad(version: requested.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        // Keep the manager only if the model did not change during the load.
        if requested == model { self.manager = manager }
        return manager
    }

    public func transcribe(_ url: URL) async throws -> TrackTranscript {
        let manager = try await loadIfNeeded()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        let tokenTimings = result.tokenTimings ?? []
        let words = buildWordTimings(from: tokenTimings).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return TrackTranscript(text: result.text, words: words, tokenTimings: tokenTimings)
    }

    /// Puts the terms of the custom vocabulary into the transcript of the audio in `url`. Without terms,
    /// it returns the transcript as it is. The first use downloads Parakeet CTC 110M from Hugging Face,
    /// then compiles and loads it with Core ML.
    public func applyVocabulary(to transcript: TrackTranscript, audio url: URL) async throws -> TrackTranscript {
        guard !vocabulary.isEmpty, !transcript.words.isEmpty else { return transcript }
        let booster = try await loadBoosterIfNeeded()
        let replacements = try await booster.replacements(for: transcript, audio: url)
        let corrected = transcript.replacing(replacements)
        let changes = replacements.map { replacement in
            "“" + transcript.words[replacement.words].map(\.text).joined(separator: " ") + "” → “\(replacement.term)”"
        }
        Log.write(
            "Custom vocabulary in \(url.lastPathComponent): "
                + (changes.isEmpty ? "no changes" : changes.joined(separator: ", ")))
        return corrected
    }

    private func loadBoosterIfNeeded() async throws -> VocabularyBooster {
        if let booster { return booster }
        let terms = vocabulary
        let models: CtcModels
        if let ctcModels {
            models = ctcModels
        } else {
            models = try await CtcModels.downloadAndLoad()
            ctcModels = models
        }
        let booster = try await VocabularyBooster(terms: terms, models: models)
        // Keep the booster only if the terms did not change during the load.
        if terms == vocabulary { self.booster = booster }
        return booster
    }

    /// On macOS 14, an Apple bug can crash the diarization models in Core ML (FluidAudio issue 878).
    /// macOS 15 fixed it, so the app finds speakers only on macOS 15 or later.
    public static var canFindSpeakers: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    /// Finds who speaks when in an audio file. The first use downloads the diarization models
    /// from Hugging Face, then compiles and loads them with Core ML.
    public func speakerTurns(in url: URL) async throws -> [SpeakerTurn] {
        let diarizer: OfflineDiarizerManager
        if let loaded = self.diarizer {
            diarizer = loaded
        } else {
            diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            self.diarizer = diarizer
        }
        let result = try await diarizer.process(url)
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
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

    /// Writes transcript.txt for the kind in session.json. A meeting gets mic.caf as "Me" and the speakers
    /// of system.caf as "Speaker 1", "Speaker 2" and so on. A note gets the speakers of mic.caf the same way.
    /// Voice input gets plain text. Without diarization, the system track is "Others" and a note is "Speaker".
    /// The terms of the custom vocabulary of the transcriber replace the words that the model heard for them.
    /// If one meeting track fails, the transcript holds the other track. A failed track, a failed
    /// diarization or a failed custom vocabulary adds a warning to the outcome.
    public static func run(
        folder: MeetingFolder, transcriber: Transcriber, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        let session = try? SessionInfo.load(from: folder.sessionURL)
        let kind = session?.kind ?? .meeting
        if kind == .voice {
            return try await runVoice(folder: folder, transcriber: transcriber, progress: progress)
        }
        var tracks = [
            (name: "mic", speaker: kind == .meeting ? "Me" : "Speaker", findSpeakers: kind == .note,
             audio: folder.micURL, text: folder.micTextURL, offset: session?.micOffset ?? 0, peak: session?.micPeak)
        ]
        if kind == .meeting {
            tracks.append(
                (name: "system", speaker: "Others", findSpeakers: true, audio: folder.systemURL,
                 text: folder.systemTextURL, offset: session?.systemOffset ?? 0, peak: session?.systemPeak))
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
                var result = try await transcriber.transcribe(track.audio)
                Log.write(
                    "Transcribed \(track.name) track of \(folder.name) in "
                        + String(format: "%.1f s: %d words", Date().timeIntervalSince(started), result.words.count))
                result = await withVocabulary(
                    result, audio: track.audio, track: track.name, transcriber: transcriber, progress: progress,
                    warnings: &warnings)
                try result.text.write(to: track.text, atomically: true, encoding: .utf8)
                var turns: [SpeakerTurn] = []
                if track.findSpeakers, !result.words.isEmpty, Transcriber.canFindSpeakers {
                    progress("Finding the speakers in the \(track.name) audio…")
                    let started = Date()
                    do {
                        turns = try await transcriber.speakerTurns(in: track.audio)
                        Log.write(
                            "Found \(Set(turns.map(\.speaker)).count) speakers in the \(track.name) track of "
                                + "\(folder.name) in " + String(format: "%.1f s", Date().timeIntervalSince(started)))
                    } catch {
                        warnings.append(
                            "The app could not find the speakers in the \(track.name) track: "
                                + error.localizedDescription)
                        Log.write("Diarization of \(track.name) track in \(folder.name) failed: \(error)")
                    }
                }
                linesPerTrack.append(
                    TranscriptMerger.lines(
                        from: result.words, fallbackText: result.text, speaker: track.speaker, turns: turns,
                        offset: track.offset))
            } catch {
                warnings.append("The \(track.name) track failed: \(error.localizedDescription)")
                Log.write("Transcription of \(track.name) track in \(folder.name) failed: \(error)")
            }
        }
        guard !linesPerTrack.isEmpty else { throw Failure.nothingTranscribed(warnings) }

        let lines = TranscriptMerger.merge(linesPerTrack)
        let transcript = TranscriptMerger.render(lines)
        try transcript.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        // The new lines have none of the changes of the user.
        var info = MeetingInfo.load(from: folder.infoURL)
        if info.linesEdited {
            info.linesEdited = false
            try? info.save(to: folder.infoURL)
        }
        return Outcome(transcript: transcript, lineCount: lines.count, warnings: warnings)
    }

    private static func runVoice(
        folder: MeetingFolder, transcriber: Transcriber, progress: @Sendable (String) -> Void
    ) async throws -> Outcome {
        progress("Transcribing…")
        var warnings: [String] = []
        let result = await withVocabulary(
            try await transcriber.transcribe(folder.micURL), audio: folder.micURL, track: nil,
            transcriber: transcriber, progress: progress, warnings: &warnings)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try (text.isEmpty ? "" : text + "\n").write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        Log.write("Transcribed voice input \(folder.name): \(result.words.count) words")
        return Outcome(transcript: text, lineCount: text.isEmpty ? 0 : 1, warnings: warnings)
    }

    /// The transcript with the terms of the custom vocabulary. If that fails, the transcript stays as it is,
    /// and a warning says why. `track` names the track in the messages.
    private static func withVocabulary(
        _ result: TrackTranscript, audio: URL, track: String?, transcriber: Transcriber,
        progress: @Sendable (String) -> Void, warnings: inout [String]
    ) async -> TrackTranscript {
        let terms = await transcriber.vocabulary
        guard !terms.isEmpty, !result.words.isEmpty else { return result }
        progress("Applying the custom vocabulary" + (track.map { " to the \($0) audio" } ?? "") + "…")
        do {
            return try await transcriber.applyVocabulary(to: result, audio: audio)
        } catch {
            warnings.append(
                "The app could not use the custom vocabulary" + (track.map { " on the \($0) track" } ?? "") + ": "
                    + error.localizedDescription)
            Log.write("Custom vocabulary on \(audio.path) failed: \(error)")
            return result
        }
    }
}
