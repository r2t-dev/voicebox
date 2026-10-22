import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A global hotkey that reports when the keys go down and come up. It uses the Carbon hotkey API,
/// which needs no permission, because it sees only this one key combination.
@MainActor
final class GlobalHotKey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false

    /// Control-Option-Space by default.
    init?(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey) {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { hotKey.handle(pressed: pressed) }
            return noErr
        }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard
            InstallEventHandler(
                GetApplicationEventTarget(), handler, eventTypes.count, &eventTypes, selfPointer, &handlerRef) == noErr
        else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4D52_4543), id: 1)  // "MREC"
        guard
            RegisterEventHotKey(
                UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
        else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    private func handle(pressed: Bool) {
        // Ignore a repeated press while the keys stay down.
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onPress() : onRelease()
    }
}

/// Pastes text into the app that has the keyboard focus, with Command-V.
/// Sending key presses to another app needs the Accessibility permission.
enum CursorPaste {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that leads to the Accessibility settings.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Sends Command-V. The text must be on the clipboard already.
    static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
