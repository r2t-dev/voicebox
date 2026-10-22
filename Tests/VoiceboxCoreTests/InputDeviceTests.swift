import Foundation
import Testing

@testable import VoiceboxCore

struct InputDeviceTests {
    // The devices depend on the Mac. On a Mac without inputs, the list is empty.
    @Test func findsEachListedDeviceByItsUID() {
        let devices = InputDevice.all()
        for device in devices {
            #expect(!device.uid.isEmpty && !device.name.isEmpty)
            #expect(device.audioDeviceID != nil)
        }
        if let current = InputDevice.systemDefault() {
            #expect(devices.contains(current))
        }
    }

    @Test func aDeviceThatIsNotConnectedHasNoID() {
        let missing = InputDevice(uid: "Voicebox-test-missing-device", name: "Missing")
        #expect(!missing.isConnected)
        #expect(throws: RecorderError.self) {
            try MicRecorder().start(
                writingTo: FileManager.default.temporaryDirectory.appendingPathComponent("unused.caf"), device: missing)
        }
    }

    @Test func savesAndLoadsAsJSON() throws {
        let device = InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        let data = try JSONEncoder().encode(device)
        #expect(try JSONDecoder().decode(InputDevice.self, from: data) == device)
    }
}
