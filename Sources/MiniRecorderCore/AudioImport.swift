import AVFoundation

/// Makes a note from an audio file that the app did not record.
public enum AudioImport {
    public enum Failure: LocalizedError {
        case unreadable(String)
        case noAudio(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Voicebox cannot read the audio in “\(name)”."
            case .noAudio(let name): return "“\(name)” holds no audio."
            }
        }
    }

    /// Creates a note folder that starts at `date`, with the audio of `source` as mic.caf. The note then
    /// plays, transcribes and expires like a recorded note. The file name becomes the title.
    /// If a step fails, the folder goes away again. The source file stays as it is.
    public static func makeNote(
        from source: URL, at date: Date = Date(), in root: URL = MeetingFolder.root
    ) throws -> MeetingFolder {
        let name = source.lastPathComponent
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw Failure.unreadable(name)
        }
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw Failure.unreadable(name)
        }

        let folder = try MeetingFolder.create(startedAt: date, in: root)
        do {
            // The processing format is Float32 at the rate and channel count of the file.
            let output = try AVAudioFile(
                forWriting: folder.micURL, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            var mic = TrackStats.Snapshot()
            // The length of a compressed file can be an estimate, so an empty read also ends the copy.
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                mic.frames += Int64(buffer.frameLength)
                mic.peak = max(mic.peak, buffer.peak)
            }
            guard mic.frames > 0 else { throw Failure.noAudio(name) }

            let duration = Double(mic.frames) / format.sampleRate
            try SessionInfo(kind: .note, startedAt: date, stoppedAt: date + duration, mic: mic, system: .init())
                .save(to: folder.sessionURL)
            try MeetingInfo(title: source.deletingPathExtension().lastPathComponent).save(to: folder.infoURL)
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
        return folder
    }
}
