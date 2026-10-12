import AppKit
import CoreGraphics
import OneCursorCore

/// Posts synthetic mouse and keyboard events (client mode).
final class EventInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let keys = KeyMapping()
    private(set) var position = CGPoint.zero
    private var buttons: Set<Int> = []
    private var modifierFlags: CGEventFlags = []
    /// Key button from the server -> the virtual key we pressed for it.
    private var pressed: [Int: UInt16] = [:]
    private var lastClick: (button: Int, time: TimeInterval, position: CGPoint, count: Int)?
    private var wheelRemainder = (x: 0.0, y: 0.0)

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    func syncPosition() {
        position = CGEvent(source: nil)?.location ?? .zero
    }

    func warp(to p: CGPoint) {
        position = p
        CGWarpMouseCursorPosition(p)
        post(mouse: .mouseMoved, button: .left)
    }

    func move(to p: CGPoint) {
        position = p
        let type: CGEventType
        let button: CGMouseButton
        if buttons.contains(MouseButton.left) {
            type = .leftMouseDragged; button = .left
        } else if buttons.contains(MouseButton.right) {
            type = .rightMouseDragged; button = .right
        } else if !buttons.isEmpty {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }
        post(mouse: type, button: button)
    }

    func button(_ b: Int, down: Bool) {
        if down { buttons.insert(b) } else { buttons.remove(b) }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch b {
        case MouseButton.left:
            type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case MouseButton.right:
            type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        case MouseButton.middle:
            type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        case MouseButton.extra0:
            type = down ? .otherMouseDown : .otherMouseUp; cgButton = CGMouseButton(rawValue: 3)!
        case MouseButton.extra1:
            type = down ? .otherMouseDown : .otherMouseUp; cgButton = CGMouseButton(rawValue: 4)!
        default:
            return
        }
        var clicks = 1
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == b, now - last.time < NSEvent.doubleClickInterval,
               abs(last.position.x - position.x) < 4, abs(last.position.y - position.y) < 4 {
                clicks = last.count + 1
            }
            lastClick = (b, now, position, clicks)
        } else {
            clicks = lastClick?.count ?? 1
        }
        post(mouse: type, button: cgButton, clicks: clicks)
    }

    /// Barrier units: +120 per notch, positive = up/right.
    func wheel(dx: Int, dy: Int) {
        // Three lines per notch, like Barrier's macOS client.
        let y = Double(dy) * 3 / 120 + wheelRemainder.y
        let x = Double(-dx) * 3 / 120 + wheelRemainder.x
        let iy = Int32(y), ix = Int32(x)
        wheelRemainder = (x - Double(ix), y - Double(iy))
        guard iy != 0 || ix != 0 else { return }
        let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }

    func key(_ keyID: Int, modifiers: Int, button: Int, action: ServerEngine.KeyAction, count: Int) {
        if KeyID.isModifier(keyID) || keyID == KeyID.capsLock {
            modifierKey(keyID, down: action != .up)
            return
        }
        switch action {
        case .down, .repeat:
            for _ in 0..<max(count, 1) { press(keyID, modifiers: modifiers, button: button, isRepeat: action == .repeat) }
        case .up:
            let upFlags = modifierFlags.union(self.flags(for: modifiers))
            if let code = pressed.removeValue(forKey: button) {
                post(key: code, down: false, flags: upFlags)
            } else if let stroke = keys.stroke(for: keyID) {
                post(key: stroke.keyCode, down: false, flags: upFlags)
            }
        }
    }

    /// Releases everything we hold (on leave or disconnect).
    func releaseAll() {
        for (_, code) in pressed { post(key: code, down: false, flags: []) }
        pressed = [:]
        for b in buttons { button(b, down: false) }
        if !modifierFlags.isEmpty {
            modifierFlags = []
            CGEvent(source: source)?.post(tap: .cghidEventTap)
        }
    }

    private func press(_ keyID: Int, modifiers: Int, button: Int, isRepeat: Bool) {
        let modFlags = flags(for: modifiers)
        if let stroke = keys.stroke(for: keyID) {
            // With Command/Control held use the plain key (Cmd+C), otherwise add the Shift/Option the layout needs.
            let shortcut = modFlags.contains(.maskCommand) || modFlags.contains(.maskControl)
            var keyFlags = modifierFlags.union(modFlags)
            if !shortcut {
                keyFlags.subtract([.maskShift, .maskAlternate])
                keyFlags.formUnion(stroke.flags)
            }
            pressed[button] = stroke.keyCode
            post(key: stroke.keyCode, down: true, flags: keyFlags, isRepeat: isRepeat)
            return
        }
        // Not on this keyboard layout: type the character directly.
        guard let scalar = Unicode.Scalar(UInt32(keyID)) else { return }
        let utf16 = Array(String(Character(scalar)).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
    }

    private func modifierKey(_ keyID: Int, down: Bool) {
        guard let code = KeyMapping.reverseSpecial[keyID], let flag = KeyMapping.flag(forModifierKeyCode: code) else { return }
        if flag == .maskAlphaShift {
            if down { modifierFlags.formSymmetricDifference(.maskAlphaShift) } else { return }
        } else if down {
            modifierFlags.insert(flag)
        } else {
            modifierFlags.remove(flag)
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = modifierFlags
        e.post(tap: .cghidEventTap)
    }

    private func flags(for barrierModifiers: Int) -> CGEventFlags {
        let m = KeyModifiers(rawValue: barrierModifiers)
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.alt) || m.contains(.altGr) { f.insert(.maskAlternate) }
        if m.contains(.superKey) || m.contains(.meta) { f.insert(.maskCommand) }
        return f
    }

    private func post(key code: UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    private func post(mouse type: CGEventType, button: CGMouseButton, clicks: Int = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        e.flags = modifierFlags
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }
}
