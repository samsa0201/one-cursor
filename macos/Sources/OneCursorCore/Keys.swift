import Foundation

/// Barrier key ids: printable keys use their Unicode code point, special keys
/// the 0xE000-0xEFFF range (X11 keysyms with 0xFF00 moved to 0xEF00).
public enum KeyID {
    public static let none = 0x0000
    public static let backSpace = 0xEF08
    public static let tab = 0xEF09
    public static let `return` = 0xEF0D
    public static let pause = 0xEF13
    public static let scrollLock = 0xEF14
    public static let escape = 0xEF1B
    public static let delete = 0xEFFF
    public static let home = 0xEF50
    public static let left = 0xEF51
    public static let up = 0xEF52
    public static let right = 0xEF53
    public static let down = 0xEF54
    public static let pageUp = 0xEF55
    public static let pageDown = 0xEF56
    public static let end = 0xEF57
    public static let print = 0xEF61
    public static let insert = 0xEF63
    public static let menu = 0xEF67
    public static let help = 0xEF6A
    public static let numLock = 0xEF7F
    public static let kpEnter = 0xEF8D
    public static let kpEqual = 0xEFBD
    public static let kpMultiply = 0xEFAA
    public static let kpAdd = 0xEFAB
    public static let kpSubtract = 0xEFAD
    public static let kpDecimal = 0xEFAE
    public static let kpDivide = 0xEFAF
    public static let kp0 = 0xEFB0
    public static let f1 = 0xEFBE
    public static let shiftL = 0xEFE1
    public static let shiftR = 0xEFE2
    public static let controlL = 0xEFE3
    public static let controlR = 0xEFE4
    public static let capsLock = 0xEFE5
    public static let metaL = 0xEFE7
    public static let metaR = 0xEFE8
    public static let altL = 0xEFE9
    public static let altR = 0xEFEA
    public static let superL = 0xEFEB
    public static let superR = 0xEFEC
    public static let altGr = 0xEF7E
    public static let audioMute = 0xE0AD
    public static let audioDown = 0xE0AE
    public static let audioUp = 0xE0AF
    public static let audioNext = 0xE0B0
    public static let audioPrev = 0xE0B1
    public static let audioPlay = 0xE0B3
    public static let brightnessDown = 0xE0B8
    public static let brightnessUp = 0xE0B9
    public static let missionControl = 0xE0C0
    public static let launchpad = 0xE0C1

    /// Function key Fn (1-based).
    public static func f(_ n: Int) -> Int { f1 + n - 1 }

    public static func isModifier(_ id: Int) -> Bool { (shiftL...0xEFEE).contains(id) || id == altGr }
}

public struct KeyModifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 0x0001)
    public static let control = KeyModifiers(rawValue: 0x0002)
    public static let alt = KeyModifiers(rawValue: 0x0004)
    public static let meta = KeyModifiers(rawValue: 0x0008)
    public static let superKey = KeyModifiers(rawValue: 0x0010)
    public static let altGr = KeyModifiers(rawValue: 0x0020)
    public static let capsLock = KeyModifiers(rawValue: 0x1000)
    public static let numLock = KeyModifiers(rawValue: 0x2000)
    public static let scrollLock = KeyModifiers(rawValue: 0x4000)

    /// Modifiers that are toggled rather than held.
    public static let toggles: KeyModifiers = [.capsLock, .numLock, .scrollLock]
}

/// Modifier ids used by the modifier remapping options and config (`super = ctrl`).
public enum ModifierID: Int, CaseIterable, Codable {
    case none = 0, shift, control, alt, meta, superKey, altGr

    public init?(configName: String) {
        switch configName.lowercased() {
        case "shift": self = .shift
        case "ctrl", "control": self = .control
        case "alt", "option": self = .alt
        case "meta": self = .meta
        case "super", "command", "cmd", "win": self = .superKey
        case "altgr": self = .altGr
        case "none": self = .none
        default: return nil
        }
    }

    public var configName: String {
        switch self {
        case .none: return "none"
        case .shift: return "shift"
        case .control: return "ctrl"
        case .alt: return "alt"
        case .meta: return "meta"
        case .superKey: return "super"
        case .altGr: return "altgr"
        }
    }

    /// The option id that remaps this modifier on a client.
    public var optionID: Int? {
        switch self {
        case .none: return nil
        case .shift: return OptionID.code("MMFS")
        case .control: return OptionID.code("MMFC")
        case .alt: return OptionID.code("MMFA")
        case .meta: return OptionID.code("MMFM")
        case .superKey: return OptionID.code("MMFR")
        case .altGr: return OptionID.code("MMFG")
        }
    }

    public var mask: KeyModifiers {
        switch self {
        case .none: return []
        case .shift: return .shift
        case .control: return .control
        case .alt: return .alt
        case .meta: return .meta
        case .superKey: return .superKey
        case .altGr: return .altGr
        }
    }

    /// Left/right key ids for this modifier.
    public var keys: (Int, Int) {
        switch self {
        case .none: return (KeyID.none, KeyID.none)
        case .shift: return (KeyID.shiftL, KeyID.shiftR)
        case .control: return (KeyID.controlL, KeyID.controlR)
        case .alt: return (KeyID.altL, KeyID.altR)
        case .meta: return (KeyID.metaL, KeyID.metaR)
        case .superKey: return (KeyID.superL, KeyID.superR)
        case .altGr: return (KeyID.altGr, KeyID.altGr)
        }
    }
}

/// Applies a server's modifier remapping (MMFx options) to key ids and masks.
public struct ModifierTranslator {
    private var table: [ModifierID: ModifierID] = [:]

    public init() {}

    public mutating func reset() { table = [:] }

    public mutating func map(_ from: ModifierID, to: ModifierID) { table[from] = to }

    public func translateKey(_ id: Int) -> Int {
        for mod in ModifierID.allCases where mod != .none {
            let (l, r) = mod.keys
            if id == l || id == r {
                let target = table[mod] ?? mod
                if target == .none { return KeyID.none }
                return id == l ? target.keys.0 : target.keys.1
            }
        }
        return id
    }

    public func translateMask(_ mask: Int) -> Int {
        let all: KeyModifiers = [.shift, .control, .alt, .meta, .superKey, .altGr]
        var out = mask & ~all.rawValue
        for mod in ModifierID.allCases where mod != .none && mask & mod.mask.rawValue != 0 {
            out |= (table[mod] ?? mod).mask.rawValue
        }
        return out
    }
}

public enum MouseButton {
    public static let left = 1
    public static let middle = 2
    public static let right = 3
    public static let extra0 = 4
    public static let extra1 = 5
}

public enum OptionID {
    public static func code(_ s: String) -> Int {
        let b = Array(s.utf8)
        precondition(b.count == 4)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    public static func name(_ id: Int) -> String {
        let bytes = [UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
                     UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id)]
        return String(decoding: bytes, as: UTF8.self)
    }

    public static let heartbeat = code("HART")
    public static let relativeMouseMoves = code("MDLT")
    public static let screenSaverSync = code("SSVR")
    public static let clipboardSharing = code("CLPS")
}
