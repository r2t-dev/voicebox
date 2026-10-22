import AVFoundation
import Testing

@testable import MiniRecorderCore

struct AudioImportTests {
    private let fileManager = FileManager.default
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTemporaryFolder() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("MiniRecorderTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 16-bit stereo WAV file at 16 kHz with a tone of `amplitude`.
    private func writeTone(to url: URL, frames: AVAudioFrameCount, amplitude: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
        guard frames > 0 else { return }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / 16_000)
            }
        }
        try file.write(from: buffer)
    }

    @Test func makesANoteThatHoldsTheAudioOfTheFile() throws {
        let root = try makeTemporaryFolder()
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("Team call.wav")
        try writeTone(to: source, frames: 24_000, amplitude: 0.5)

        let folder = try AudioImport.makeNote(from: source, at: started, in: root.appendingPathComponent("notes"))

        #expect(MeetingFolder.date(fromName: folder.name) == started)
        let audio = try AVAudioFile(forReading: folder.micURL)
        #expect(audio.length == 24_000)
        #expect(audio.fileFormat.sampleRate == 16_000 && audio.fileFormat.channelCount == 2)
        let session = try SessionInfo.load(from: folder.sessionURL)
        #expect(session.kind == .note && session.micFrames == 24_000 && session.micOffset == 0)
        #expect(abs(session.micPeak - 0.5) < 0.001)
        let note = MeetingRecord.load(folder)
        #expect(note.kind == .note && note.title == "Team call" && note.hasAudio)
        #expect(note.startedAt == started && note.duration == 1.5)
        #expect(note.transcript == nil)
        #expect(fileManager.fileExists(atPath: source.path))
    }

    @Test func leavesNoFolderForAFileThatIsNotAudio() throws {
        let root = try makeTemporaryFolder()
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.mp3")
        try "not audio".write(to: source, atomically: true, encoding: .utf8)
        let notes = root.appendingPathComponent("notes")

        #expect(throws: AudioImport.Failure.self) { try AudioImport.makeNote(from: source, at: started, in: notes) }
        #expect(!fileManager.fileExists(atPath: notes.path))
    }

    @Test func removesTheFolderOfAFileWithoutAudio() throws {
        let root = try makeTemporaryFolder()
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("empty.wav")
        try writeTone(to: source, frames: 0, amplitude: 0)
        let notes = root.appendingPathComponent("notes")

        #expect(throws: AudioImport.Failure.self) { try AudioImport.makeNote(from: source, at: started, in: notes) }
        #expect(try fileManager.contentsOfDirectory(atPath: notes.path).isEmpty)
    }
}
