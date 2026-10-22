import AVFoundation
import CoreAudio

/// Records everything that the Mac plays into one CAF file, through a Core Audio process tap.
///
/// The setup follows Narada: a global stereo tap, then a private aggregate device whose main
/// sub-device is the default output device and whose tap list holds the tap, then an IO block.
public final class SystemAudioRecorder {
    public let stats = TrackStats()
    public private(set) var format: AVAudioFormat?
    public private(set) var excludesOwnAudio = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var tapBuffers: UnsafeMutableAudioBufferListPointer?

    public init() {}

    deinit { stop() }

    public func start(writingTo url: URL) throws {
        do {
            try startTap(writingTo: url)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(writingTo url: URL) throws {
        let outputUID = try defaultOutputDeviceUID()

        // Leave out the sound of this app, such as playback in the dashboard.
        let excluded = ownProcessObject().map { [$0] } ?? []
        excludesOwnAudio = !excluded.isEmpty
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "AudioHardwareCreateProcessTap")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voicebox-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice")

        var asbd = try getProperty(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        // A Bluetooth headset in call (HFP) mode runs below the rate that the tap reports.
        // Write at the device rate, so that the file length matches the wall clock.
        if let deviceRate = try? getProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
            deviceRate > 0
        {
            asbd.mSampleRate = deviceRate
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.badFormat }
        self.format = format

        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.file = file

        // If the output device also has inputs (a USB headset, for example), the aggregate
        // delivers those streams too. The tap streams come last.
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let tapBuffers = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
        self.tapBuffers = tapBuffers
        let stats = stats

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, _, _ in
                let delivered = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard delivered.count >= tapBufferCount else { return }
                for index in 0..<tapBufferCount {
                    tapBuffers[index] = delivered[delivered.count - tapBufferCount + index]
                }
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: format, bufferListNoCopy: tapBuffers.unsafePointer, deallocator: nil)
                else { return }
                stats.record(hostTime: inputTime.pointee.mHostTime, buffer: buffer)
                // Good enough for a prototype: AVAudioFile does file I/O on the real-time thread.
                // Narada uses ExtAudioFileWriteAsync to keep that I/O off this thread.
                try? file.write(from: buffer)
            }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)

        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        if let tapBuffers { free(tapBuffers.unsafeMutablePointer) }
        tapBuffers = nil
    }

    /// Starts a tap for one second, so that macOS shows the System Audio Recording prompt
    /// before the first real recording. Narada does the same with its PermissionWarmup tap.
    public static func warmUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voicebox-warmup-\(UUID().uuidString).caf")
        let recorder = SystemAudioRecorder()
        try recorder.start(writingTo: url)
        try? await Task.sleep(for: .seconds(1))
        recorder.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
