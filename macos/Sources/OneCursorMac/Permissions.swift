import AppKit
import ApplicationServices
import CoreGraphics

/// The two privacy permissions One Cursor needs on macOS.
public enum Permissions {
    /// Required to intercept (event tap) and to post keyboard/mouse events.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Required to read keyboard input in the event tap on recent macOS versions.
    public static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
