import AppKit

/// Shows the app in the Dock, in the Command-Tab switcher and in the menu bar while the dashboard or the settings
/// window is open. Without these windows, the app is only the menu bar icon, as LSUIElement in Info.plist says.
@MainActor
enum DockPresence {
    private static var openWindows = Set<ObjectIdentifier>()

    /// Call before the app activates, so that the window opens as the window of a regular app.
    static func windowOpened(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        if openWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
