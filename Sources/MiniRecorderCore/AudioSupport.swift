import AVFoundation
import Accelerate
import CoreAudio
import os

public enum RecorderError: LocalizedError {
    case coreAudio(String, OSStatus)
    case badFormat
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let call, let status):
            return "\(call) failed with OSStatus \(status) (\(fourCharCode(status)))."
        case .badFormat:
            return "The system audio tap reported a format that AVAudioFormat cannot read."
        case .noInputDevice:
            return "No microphone is available."
        }
    }
}

func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw RecorderError.coreAudio(call, status) }
}

private func fourCharCode(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(status)" }
    return String(decoding: bytes, as: UTF8.self)
}

/// Reads a fixed-size property value, such as an ID, a sample rate or a stream format.
func getProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "AudioObjectGetPropertyData")
    return value
}

func defaultOutputDeviceUID() throws -> String {
    let deviceID = try getProperty(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
        initial: AudioDeviceID(kAudioObjectUnknown))
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "kAudioDevicePropertyDeviceUID")
    guard let uid else { throw RecorderError.coreAudio("kAudioDevicePropertyDeviceUID", -1) }
    return uid.takeRetainedValue() as String
}

/// The Core Audio process object of this app, or nil if Core Audio does not know the app yet.
func ownProcessObject() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var pid = getpid()
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

/// Facts about one recorded track that the transcript step needs after Stop.
/// The audio callbacks write it, and the main thread reads it after the recorder stops.
public final class TrackStats: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var firstHostTime: UInt64 = 0
        public var peak: Float = 0
        public var frames: Int64 = 0

        /// An empty track, for a recording without system audio.
        public init() {}
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    func record(hostTime: UInt64, frames: Int, peak: Float) {
        state.withLock {
            if $0.firstHostTime == 0 { $0.firstHostTime = hostTime }
            $0.frames += Int64(frames)
            $0.peak = max($0.peak, peak)
        }
    }

    func record(hostTime: UInt64, buffer: AVAudioPCMBuffer) {
        record(hostTime: hostTime, frames: Int(buffer.frameLength), peak: buffer.peak)
    }
}

extension AVAudioPCMBuffer {
    var peak: Float {
        guard let channels = floatChannelData else { return 0 }
        let samplesPerChannel = vDSP_Length(Int(frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1))
        let channelCount = format.isInterleaved ? 1 : Int(format.channelCount)
        var result: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, samplesPerChannel)
            result = max(result, channelPeak)
        }
        return result
    }
}

public func hostTimeToSeconds(_ hostTime: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}
