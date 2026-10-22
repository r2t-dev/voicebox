import AppKit
import Carbon.HIToolbox

/// The actions that can have a global shortcut.
enum HotKeyAction: String, CaseIterable, Codable {
    case voiceInput, meeting, notes, dashboard

    var title: String {
        switch self {
        case .voiceInput: return "Voice input (hold or tap)"
        case .meeting: return "Start or stop a meeting"
        case .notes: return "Start or stop notes"
        case .dashboard: return "Open the dashboard"
        }
    }

    var id: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

/// A key with modifier keys, in the Carbon form that RegisterEventHotKey takes.
struct Shortcut: Codable, Equatable {
    let keyCode: Int
    let modifiers: Int

    static let defaultVoiceInput = Shortcut(keyCode: kVK_Space, modifiers: controlKey | optionKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    /// A global shortcut needs Control, Option or Command, except on a function key.
    var isUsable: Bool {
        modifiers & (controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(keyCode)
    }

    var display: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// F1 to F20, in order. The key codes themselves are not in order.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    // Names by key position on a US keyboard, so that the label does not depend on the input layout.
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"),
        ]
        for (code, name) in letters { names[code] = name }
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()
}

/// Global shortcuts through the Carbon hotkey API. It needs no permission, because it sees
/// only the registered key combinations.
@MainActor
final class HotKeyCenter {
    struct Handlers {
        let onPress: () -> Void
        let onRelease: () -> Void
    }

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, handlers: Handlers)] = [:]
    private var keysDown: Set<UInt32> = []

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { center.handle(id: hotKeyID.id, pressed: pressed) }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Returns noErr, or the OSStatus with which macOS refused the shortcut.
    func register(_ action: HotKeyAction, _ shortcut: Shortcut, handlers: Handlers) -> OSStatus {
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D52_4543), id: action.id)  // "MREC"
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { registered[action.id] = (ref, handlers) }
        return status
    }

    static func refusalMessage(_ status: OSStatus, for shortcut: Shortcut) -> String {
        status == OSStatus(eventHotKeyExistsErr)
            ? "Another app uses \(shortcut.display)." : "macOS refused \(shortcut.display) (error \(status))."
    }

    func unregister(_ action: HotKeyAction) {
        if let entry = registered.removeValue(forKey: action.id) { UnregisterEventHotKey(entry.ref) }
        keysDown.remove(action.id)
    }

    func unregisterAll() {
        HotKeyAction.allCases.forEach(unregister)
    }

    private func handle(id: UInt32, pressed: Bool) {
        guard let handlers = registered[id]?.handlers else { return }
        // Ignore a repeated press while the keys stay down.
        guard pressed != keysDown.contains(id) else { return }
        if pressed {
            keysDown.insert(id)
            handlers.onPress()
        } else {
            keysDown.remove(id)
            handlers.onRelease()
        }
    }
}
