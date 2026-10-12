import Carbon
import CoreGraphics
import OneCursorCore

/// Translates between macOS virtual key codes and Barrier key ids.
public final class KeyMapping {
    public init() {}

    /// Special (non-character) keys, macOS virtual key code -> Barrier key id.
    static let special: [UInt16: Int] = [
        0x24: KeyID.return, 0x30: KeyID.tab, 0x33: KeyID.backSpace, 0x35: KeyID.escape,
        0x75: KeyID.delete, 0x73: KeyID.home, 0x77: KeyID.end, 0x74: KeyID.pageUp, 0x79: KeyID.pageDown,
        0x7B: KeyID.left, 0x7C: KeyID.right, 0x7D: KeyID.down, 0x7E: KeyID.up,
        0x72: KeyID.insert, // "Help" sits where Insert is on PC keyboards
        0x6E: KeyID.menu,
        0x7A: KeyID.f(1), 0x78: KeyID.f(2), 0x63: KeyID.f(3), 0x76: KeyID.f(4), 0x60: KeyID.f(5),
        0x61: KeyID.f(6), 0x62: KeyID.f(7), 0x64: KeyID.f(8), 0x65: KeyID.f(9), 0x6D: KeyID.f(10),
        0x67: KeyID.f(11), 0x6F: KeyID.f(12), 0x69: KeyID.f(13), 0x6B: KeyID.f(14), 0x71: KeyID.f(15),
        0x6A: KeyID.f(16), 0x40: KeyID.f(17), 0x4F: KeyID.f(18), 0x50: KeyID.f(19), 0x5A: KeyID.f(20),
        0x4C: KeyID.kpEnter, 0x47: KeyID.numLock, 0x41: KeyID.kpDecimal, 0x43: KeyID.kpMultiply,
        0x45: KeyID.kpAdd, 0x4B: KeyID.kpDivide, 0x4E: KeyID.kpSubtract, 0x51: KeyID.kpEqual,
        0x52: KeyID.kp0, 0x53: KeyID.kp0 + 1, 0x54: KeyID.kp0 + 2, 0x55: KeyID.kp0 + 3, 0x56: KeyID.kp0 + 4,
        0x57: KeyID.kp0 + 5, 0x58: KeyID.kp0 + 6, 0x59: KeyID.kp0 + 7, 0x5B: KeyID.kp0 + 8, 0x5C: KeyID.kp0 + 9,
        0x48: KeyID.audioUp, 0x49: KeyID.audioDown, 0x4A: KeyID.audioMute,
        // Modifiers
        0x38: KeyID.shiftL, 0x3C: KeyID.shiftR, 0x3B: KeyID.controlL, 0x3E: KeyID.controlR,
        0x3A: KeyID.altL, 0x3D: KeyID.altR, 0x37: KeyID.superL, 0x36: KeyID.superR, 0x39: KeyID.capsLock,
    ]

    static let reverseSpecial: [Int: UInt16] = {
        var r: [Int: UInt16] = [:]
        // Prefer the left-hand modifier and the main keypad when several codes map to one id.
        for (code, id) in special.sorted(by: { $0.key > $1.key }) { r[id] = code }
        r[KeyID.shiftL] = 0x38
        r[KeyID.controlL] = 0x3B
        r[KeyID.altL] = 0x3A
        r[KeyID.superL] = 0x37
        r[KeyID.metaL] = 0x37
        r[KeyID.metaR] = 0x36
        r[KeyID.altGr] = 0x3D
        return r
    }()

    // MARK: Server side: capture

    /// Key id for a key press, using the current keyboard layout for characters.
    /// Shift, Option and Caps Lock are applied (so Shift+1 gives "!"), Command and
    /// Control are not (the receiving side applies those itself).
    public func keyID(keyCode: UInt16, flags: CGEventFlags) -> Int {
        if let id = Self.special[keyCode] { return id }
        guard let s = character(for: keyCode, shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate),
                                capsLock: flags.contains(.maskAlphaShift)),
              let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else {
            return KeyID.none
        }
        return Int(scalar.value)
    }

    /// Barrier modifier mask for CoreGraphics event flags.
    public static func modifiers(_ flags: CGEventFlags) -> Int {
        var m: KeyModifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.alt) }
        if flags.contains(.maskCommand) { m.insert(.superKey) }
        if flags.contains(.maskAlphaShift) { m.insert(.capsLock) }
        return m.rawValue
    }

    /// The flag bit that a modifier key toggles.
    public static func flag(forModifierKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case 0x38, 0x3C: return .maskShift
        case 0x3B, 0x3E: return .maskControl
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        case 0x39: return .maskAlphaShift
        default: return nil
        }
    }

    // MARK: Client side: injection

    public struct Stroke {
        public let keyCode: UInt16
        public let flags: CGEventFlags
    }

    private var layoutID: String?
    private var charMap: [String: Stroke] = [:]

    /// Finds the key (and Shift/Option state) producing `keyID` on the current layout.
    public func stroke(for keyID: Int) -> Stroke? {
        if let code = Self.reverseSpecial[keyID] { return Stroke(keyCode: code, flags: []) }
        guard let scalar = Unicode.Scalar(UInt32(keyID)) else { return nil }
        refreshCharMap()
        return charMap[String(Character(scalar))]
    }

    private func refreshCharMap() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        var id = "?"
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        if id == layoutID, !charMap.isEmpty { return }
        layoutID = id
        var map: [String: Stroke] = [:]
        let combos: [(Bool, Bool, CGEventFlags)] = [(false, false, []), (true, false, .maskShift),
                                                    (false, true, .maskAlternate), (true, true, [.maskShift, .maskAlternate])]
        for (shift, option, flags) in combos {
            for code in UInt16(0)..<UInt16(128) where Self.special[code] == nil {
                guard let s = character(for: code, shift: shift, option: option, capsLock: false), !s.isEmpty else { continue }
                if map[s] == nil { map[s] = Stroke(keyCode: code, flags: flags) }
            }
        }
        charMap = map
    }

    /// Character produced by a key on the current keyboard layout (dead keys give their spacing form).
    func character(for keyCode: UInt16, shift: Bool, option: Bool, capsLock: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var modifierState: UInt32 = 0
        if shift { modifierState |= UInt32((shiftKey >> 8) & 0xFF) }
        if option { modifierState |= UInt32((optionKey >> 8) & 0xFF) }
        if capsLock { modifierState |= UInt32((alphaLock >> 8) & 0xFF) }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode, UInt16(kUCKeyActionDown),
                                  modifierState, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
