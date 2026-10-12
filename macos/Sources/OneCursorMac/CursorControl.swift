import CoreGraphics
import Darwin
import Foundation
import OneCursorCore

/// Hides, shows, freezes and warps the local mouse cursor.
public enum CursorControl {
    private static var hidden = false

    public static func hide() {
        guard !hidden else { return }
        allowBackgroundCursorChanges()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    public static func show() {
        guard hidden else { return }
        allowBackgroundCursorChanges()
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    /// When false, mouse motion still produces events (with deltas) but the cursor stays put.
    public static func associate(_ associated: Bool) {
        CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
    }

    public static func warp(to p: Point) {
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: p.y))
    }

    private static let warpSource = CGEventSource(stateID: .combinedSessionState)

    /// Warping normally suppresses real mouse input for 250 ms; turn that off.
    public static func disableWarpSuppression() {
        warpSource?.localEventsSuppressionInterval = 0
        // The process-wide setter is hidden from the SDK but still honoured, as Barrier relies on.
        typealias SetInterval = @convention(c) (CFTimeInterval) -> Int32
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSetLocalEventsSuppressionInterval") {
            _ = unsafeBitCast(sym, to: SetInterval.self)(0)
        }
    }

    /// Hiding the cursor only works for the frontmost app unless this private
    /// WindowServer connection property is set (the same trick Barrier uses).
    private static func allowBackgroundCursorChanges() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let conn = unsafeBitCast(connSym, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
