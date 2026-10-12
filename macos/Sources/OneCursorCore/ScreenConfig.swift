import Foundation

public enum Direction: String, Codable, CaseIterable {
    case left, right, top = "up", bottom = "down"

    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// Accepts Barrier's spellings (`up`/`down`) as well as `top`/`bottom`.
    public init?(configName: String) {
        switch configName.lowercased() {
        case "left": self = .left
        case "right": self = .right
        case "up", "top": self = .top
        case "down", "bottom": self = .bottom
        default: return nil
        }
    }
}

/// A link from one screen edge (or part of it) to another screen.
/// Ranges are fractions of the edge, 0...1, like Barrier's `left(0,50)` percentages.
public struct ScreenLink: Codable, Equatable {
    public var direction: Direction
    public var target: String
    public var sourceRange: ClosedRange<Double>
    public var targetRange: ClosedRange<Double>

    public init(direction: Direction, target: String,
                sourceRange: ClosedRange<Double> = 0...1, targetRange: ClosedRange<Double> = 0...1) {
        self.direction = direction
        self.target = target
        self.sourceRange = sourceRange
        self.targetRange = targetRange
    }
}

public struct ScreenEntry: Codable, Equatable {
    public var name: String
    public var aliases: [String]
    public var links: [ScreenLink]
    /// Modifier remapping for this screen, e.g. `[.superKey: .control]`.
    public var modifierMap: [ModifierID: ModifierID]

    public init(name: String, aliases: [String] = [], links: [ScreenLink] = [], modifierMap: [ModifierID: ModifierID] = [:]) {
        self.name = name
        self.aliases = aliases
        self.links = links
        self.modifierMap = modifierMap
    }
}

public struct ServerOptions: Codable, Equatable {
    /// Milliseconds the cursor must push against an edge before switching (0 = immediately).
    public var switchDelay: Int = 0
    /// Send relative mouse motion (DMRM) instead of absolute positions.
    public var relativeMouseMoves = false
    public var clipboardSharing = true
    /// Keep-alive interval in milliseconds.
    public var heartbeat = 3000

    public init() {}
}

/// The server's screen layout, Barrier style: named screens and directional links.
public struct ScreenConfig: Codable, Equatable {
    public var screens: [ScreenEntry]
    public var options: ServerOptions

    public init(screens: [ScreenEntry] = [], options: ServerOptions = ServerOptions()) {
        self.screens = screens
        self.options = options
    }

    /// Finds a screen by name or alias, case-insensitively.
    public func screen(named name: String) -> ScreenEntry? {
        let key = name.lowercased()
        return screens.first { $0.name.lowercased() == key || $0.aliases.contains { $0.lowercased() == key } }
    }

    public func canonicalName(_ name: String) -> String? { screen(named: name)?.name }

    /// The screen (and position along its edge) reached by leaving `from`
    /// through `direction` at fraction `t` (0...1) of that edge.
    public func neighbor(of from: String, direction: Direction, at t: Double) -> (name: String, t: Double)? {
        guard let entry = screen(named: from) else { return nil }
        for link in entry.links where link.direction == direction {
            let s = link.sourceRange
            guard t >= s.lowerBound && (t < s.upperBound || (t == s.upperBound && s.upperBound >= 1)) else { continue }
            guard let target = canonicalName(link.target) else { continue }
            let span = s.upperBound - s.lowerBound
            let local = span > 0 ? (t - s.lowerBound) / span : 0
            let d = link.targetRange
            return (target, d.lowerBound + local * (d.upperBound - d.lowerBound))
        }
        return nil
    }

    /// Options sent to a client in DSOP.
    public func clientOptions(for name: String) -> [Int] {
        var list: [Int] = []
        if let entry = screen(named: name) {
            for (from, to) in entry.modifierMap.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let id = from.optionID {
                    list += [id, to.rawValue]
                }
            }
        }
        if options.heartbeat != 3000 { list += [OptionID.heartbeat, options.heartbeat] }
        if options.relativeMouseMoves { list += [OptionID.relativeMouseMoves, 1] }
        if !options.clipboardSharing { list += [OptionID.clipboardSharing, 0] }
        return list
    }

    /// A two screen layout: `client` on the given side of `server`.
    public static func simple(server: String, clients: [(String, Direction)]) -> ScreenConfig {
        var serverEntry = ScreenEntry(name: server)
        var entries: [ScreenEntry] = []
        for (client, side) in clients {
            serverEntry.links.append(ScreenLink(direction: side, target: client))
            entries.append(ScreenEntry(name: client, links: [ScreenLink(direction: side.opposite, target: server)]))
        }
        return ScreenConfig(screens: [serverEntry] + entries)
    }
}

// MARK: - Barrier configuration file format

public extension ScreenConfig {
    /// Parses a Barrier/Synergy text configuration (`section: screens`, `links`,
    /// `aliases`, `options`). Unknown options are ignored.
    static func parseBarrier(_ text: String) throws -> ScreenConfig {
        var config = ScreenConfig()
        var section: String?
        var current: String?

        func entryIndex(_ name: String) -> Int {
            if let i = config.screens.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) { return i }
            config.screens.append(ScreenEntry(name: name))
            return config.screens.count - 1
        }

        for (number, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("section:") {
                section = lower.dropFirst("section:".count).trimmingCharacters(in: .whitespaces)
                current = nil
                continue
            }
            if lower == "end" {
                section = nil
                current = nil
                continue
            }
            guard let sec = section else {
                throw ConfigError.syntax(line: number + 1, "text outside of a section")
            }
            if line.hasSuffix(":") && !line.contains("=") {
                current = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                if sec == "screens" || sec == "links" { _ = entryIndex(current!) }
                continue
            }
            switch sec {
            case "screens":
                guard let screen = current else { throw ConfigError.syntax(line: number + 1, "option before screen name") }
                let (key, value) = try keyValue(line, number)
                if let from = ModifierID(configName: key), let to = ModifierID(configName: value) {
                    let i = entryIndex(screen)
                    config.screens[i].modifierMap[from] = to
                }
            case "aliases":
                guard let screen = current else { throw ConfigError.syntax(line: number + 1, "alias before screen name") }
                let i = entryIndex(screen)
                config.screens[i].aliases.append(line)
            case "links":
                guard let screen = current else { throw ConfigError.syntax(line: number + 1, "link before screen name") }
                let (lhs, rhs) = try keyValue(line, number)
                let (dirName, srcRange) = try parseRanged(lhs, number)
                guard let dir = Direction(configName: dirName) else {
                    throw ConfigError.syntax(line: number + 1, "unknown direction \(dirName)")
                }
                let (target, dstRange) = try parseRanged(rhs, number)
                let i = entryIndex(screen)
                config.screens[i].links.append(
                    ScreenLink(direction: dir, target: target, sourceRange: srcRange, targetRange: dstRange))
            case "options":
                let (key, value) = try keyValue(line, number)
                switch key.lowercased() {
                case "switchdelay": config.options.switchDelay = Int(value) ?? 0
                case "relativemousemoves": config.options.relativeMouseMoves = value.lowercased() == "true"
                case "clipboardsharing": config.options.clipboardSharing = value.lowercased() != "false"
                case "heartbeat": config.options.heartbeat = Int(value) ?? 3000
                default: break
                }
            default:
                break
            }
        }
        return config
    }

    /// Writes the configuration in Barrier's text format.
    func barrierText() -> String {
        var out = "section: screens\n"
        for s in screens {
            out += "\t\(s.name):\n"
            for (from, to) in s.modifierMap.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                out += "\t\t\(from.configName) = \(to.configName)\n"
            }
        }
        out += "end\n\nsection: aliases\n"
        for s in screens where !s.aliases.isEmpty {
            out += "\t\(s.name):\n"
            s.aliases.forEach { out += "\t\t\($0)\n" }
        }
        out += "end\n\nsection: links\n"
        for s in screens {
            out += "\t\(s.name):\n"
            for l in s.links {
                out += "\t\t\(l.direction.rawValue)\(rangeText(l.sourceRange)) = \(l.target)\(rangeText(l.targetRange))\n"
            }
        }
        out += "end\n\nsection: options\n"
        if options.switchDelay > 0 { out += "\tswitchDelay = \(options.switchDelay)\n" }
        if options.relativeMouseMoves { out += "\trelativeMouseMoves = true\n" }
        if !options.clipboardSharing { out += "\tclipboardSharing = false\n" }
        if options.heartbeat != 3000 { out += "\theartbeat = \(options.heartbeat)\n" }
        out += "end\n"
        return out
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case syntax(line: Int, String)

    public var description: String {
        switch self {
        case let .syntax(line, msg): return "line \(line): \(msg)"
        }
    }
}

private func keyValue(_ line: String, _ number: Int) throws -> (String, String) {
    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, !parts[0].isEmpty else { throw ConfigError.syntax(line: number + 1, "expected name = value") }
    return (parts[0], parts[1])
}

/// Parses `name` or `name(start,end)` with percentages.
private func parseRanged(_ s: String, _ number: Int) throws -> (String, ClosedRange<Double>) {
    guard let open = s.firstIndex(of: "(") else { return (s, 0...1) }
    guard s.hasSuffix(")") else { throw ConfigError.syntax(line: number + 1, "missing ) in \(s)") }
    let name = s[..<open].trimmingCharacters(in: .whitespaces)
    let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
    let nums = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard nums.count == 2, nums[0] < nums[1], nums[0] >= 0, nums[1] <= 100 else {
        throw ConfigError.syntax(line: number + 1, "invalid range in \(s)")
    }
    return (name, (nums[0] / 100)...(nums[1] / 100))
}

private func rangeText(_ r: ClosedRange<Double>) -> String {
    if r == 0...1 { return "" }
    return "(\(Int((r.lowerBound * 100).rounded())),\(Int((r.upperBound * 100).rounded())))"
}
