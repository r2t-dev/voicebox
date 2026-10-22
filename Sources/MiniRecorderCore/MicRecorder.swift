import AVFoundation

/// Records the default microphone into one CAF file, through an AVAudioEngine input-node tap.
public final class MicRecorder {
    public let stats = TrackStats()
    public private(set) var format: AVAudioFormat?

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?

    public init() {}

    deinit { stop() }

    public func start(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let stats = stats
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            stats.record(hostTime: when.isHostTimeValid ? when.hostTime : mach_absolute_time(), buffer: buffer)
            try? file.write(from: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.file = file
        self.format = format
    }

    public func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if #available(macOS 15.0, *) { file?.close() }
        self.engine = nil
        file = nil
    }
}
