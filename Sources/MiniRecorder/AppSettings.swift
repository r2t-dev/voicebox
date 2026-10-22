import Foundation
import MiniRecorderCore

/// The user's settings, saved in UserDefaults. It is an ObservableObject and not @AppStorage,
/// because the Command Line Tools have no plugin for the SwiftUI macros.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let copyTranscript = "copyTranscript"
        static let playSound = "playSound"
        static let pasteVoiceInput = "pasteVoiceInput"
        static let keepVoiceEntries = "keepVoiceEntries"
        static let model = "model"
        static let microphone = "microphone"
        static let retention = "retention"
        static let shortcuts = "shortcuts"
    }

    private let defaults = UserDefaults.standard

    /// After a meeting or notes recording.
    @Published var copyTranscript: Bool { didSet { defaults.set(copyTranscript, forKey: Key.copyTranscript) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }
    @Published var pasteVoiceInput: Bool { didSet { defaults.set(pasteVoiceInput, forKey: Key.pasteVoiceInput) } }
    @Published var keepVoiceEntries: Bool { didSet { defaults.set(keepVoiceEntries, forKey: Key.keepVoiceEntries) } }
    @Published var model: AsrModelChoice { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    /// The input for all recordings. Nil means the system default input.
    @Published var microphone: InputDevice? {
        didSet {
            if let microphone {
                save(microphone, forKey: Key.microphone)
            } else {
                defaults.removeObject(forKey: Key.microphone)
            }
        }
    }
    @Published var retention: RetentionPolicy { didSet { save(retention, forKey: Key.retention) } }
    /// Saved by the raw value of the action, so that the JSON is a plain object.
    @Published var shortcuts: [HotKeyAction: Shortcut] {
        didSet { save(Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }), forKey: Key.shortcuts) }
    }

    private init() {
        defaults.register(defaults: [
            Key.copyTranscript: true, Key.playSound: true, Key.pasteVoiceInput: true, Key.keepVoiceEntries: true,
        ])
        copyTranscript = defaults.bool(forKey: Key.copyTranscript)
        playSound = defaults.bool(forKey: Key.playSound)
        pasteVoiceInput = defaults.bool(forKey: Key.pasteVoiceInput)
        keepVoiceEntries = defaults.bool(forKey: Key.keepVoiceEntries)
        model = Self.storedModel
        microphone = Self.load(InputDevice.self, forKey: Key.microphone)
        retention = Self.load(RetentionPolicy.self, forKey: Key.retention) ?? RetentionPolicy()
        if let stored = Self.load([String: Shortcut].self, forKey: Key.shortcuts) {
            shortcuts = Dictionary(
                uniqueKeysWithValues: stored.compactMap { key, value in HotKeyAction(rawValue: key).map { ($0, value) } })
        } else {
            shortcuts = [.voiceInput: .defaultVoiceInput]
        }
    }

    /// The model setting, also for `--transcribe`, which runs before the app starts.
    nonisolated static var storedModel: AsrModelChoice {
        UserDefaults.standard.string(forKey: Key.model).flatMap(AsrModelChoice.init(rawValue:)) ?? .v3
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
