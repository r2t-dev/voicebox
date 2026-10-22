import CoreAudio
import Foundation

/// An audio input that Core Audio knows, such as the built-in microphone or a USB headset.
public struct InputDevice: Codable, Hashable, Identifiable, Sendable {
    /// The UID stays the same when the device reconnects or the Mac restarts. The settings save it.
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    /// The connected devices that have input channels, sorted by name.
    public static func all() -> [InputDevice] {
        connected().map(\.device).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The input that macOS uses now, or nil if there is none.
    public static func systemDefault() -> InputDevice? {
        let id = try? getProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
            initial: AudioDeviceID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    public var isConnected: Bool { audioDeviceID != nil }

    /// The Core Audio ID of the device, or nil if it is not connected. The ID can change at a reconnect.
    var audioDeviceID: AudioDeviceID? {
        Self.connected().first { $0.device.uid == uid }?.id
    }

    private static func connected() -> [(id: AudioDeviceID, device: InputDevice)] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), (try? getProperty(id, kAudioDevicePropertyIsHidden, initial: UInt32(0))) != 1,
                let device = device(id)
            else { return nil }
            return (id, device)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// True if the device has at least one input stream.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return InputDevice(uid: uid, name: name)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Calls `onChange` on the main queue when an audio device connects or disconnects,
/// or when the default input changes. It stops when it is released.
public final class InputDeviceObserver {
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private let listener: AudioObjectPropertyListenerBlock

    public init(onChange: @escaping () -> Void) {
        listener = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
