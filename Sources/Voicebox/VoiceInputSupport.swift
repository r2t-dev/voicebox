import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Pastes text into the app that has the keyboard focus, with Command-V.
/// Sending key presses to another app needs the Accessibility permission.
enum CursorPaste {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

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
