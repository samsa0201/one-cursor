import Foundation

public typealias ConnectionID = Int

/// Platform hooks used by `ServerEngine`. Everything is called on the engine's queue.
public protocol ServerEngineDelegate: AnyObject {
    func engine(_ engine: ServerEngine, send data: Data, to connection: ConnectionID)
    func engine(_ engine: ServerEngine, close connection: ConnectionID)
    /// The cursor moved to another screen: hide and freeze the local cursor.
    func engineDidLeavePrimary(_ engine: ServerEngine)
    /// The cursor came back: show it at `point` (global display coordinates).
    func engine(_ engine: ServerEngine, didEnterPrimaryAt point: Point)
    /// A client published new clipboard contents.
    func engine(_ engine: ServerEngine, setPrimaryClipboard content: ClipboardContent)
    func engineStateDidChange(_ engine: ServerEngine)
    func engine(_ engine: ServerEngine, log message: String)
}

public extension ServerEngineDelegate {
    func engineStateDidChange(_ engine: ServerEngine) {}
    func engine(_ engine: ServerEngine, log message: String) {}
}

/// The Barrier-compatible server logic, independent of any platform:
/// client handshakes and keep-alives, screen switching at edges, forwarding of
/// input to the active client and clipboard sharing.
///
/// Not thread safe; drive it from a single queue.
public final class ServerEngine {
    public struct ClientStatus: Equatable {
        public let name: String
        public let address: String
        public let shape: Rect?
    }

    private final class Peer {
        let id: ConnectionID
        let address: String
        var name: String?
        var decoder = FrameDecoder()
        var assembler = ClipboardAssembler()
        let openedAt: TimeInterval
        var lastReceived: TimeInterval
        var lastSent: TimeInterval
        var shape: Rect?
        var clipboardDirty = true
        /// Key button -> key id last sent down, so releases match presses.
        var pressedKeys: [Int: (keyID: Int, modifiers: Int)] = [:]
        var pressedButtons: Set<Int> = []

        init(id: ConnectionID, address: String, now: TimeInterval) {
            self.id = id
            self.address = address
            openedAt = now
            lastReceived = now
            lastSent = now
        }
    }

    public weak var delegate: ServerEngineDelegate?
    public private(set) var config: ScreenConfig
    public let primaryName: String
    public var layout: DisplayLayout
    public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var peers: [ConnectionID: Peer] = [:]
    private var byName: [String: ConnectionID] = [:]

    /// Name of the screen that currently has the cursor.
    public private(set) var activeScreen: String
    /// Cursor position on the active client, in that client's coordinates.
    private var cursor = Point(x: 0, y: 0)
    private var fractional = Point(x: 0, y: 0)
    private var sequence = 0
    private var edgePushStart: TimeInterval?
    private var primaryButtons: Set<Int> = []
    private var toggles = 0

    private var clipboard: ClipboardContent?
    private var clipboardOwner: String
    private var clipboardSequence = 0

    public init(primaryName: String, config: ScreenConfig, layout: DisplayLayout) {
        self.primaryName = config.canonicalName(primaryName) ?? primaryName
        self.config = config
        self.layout = layout
        activeScreen = self.primaryName
        clipboardOwner = self.primaryName
    }

    public var isPrimaryActive: Bool { activeScreen == primaryName }

    public var clients: [ClientStatus] {
        peers.values.compactMap { p in p.name.map { ClientStatus(name: $0, address: p.address, shape: p.shape) } }
            .sorted { $0.name < $1.name }
    }

    public func updateConfig(_ newConfig: ScreenConfig) {
        config = newConfig
        // Drop clients that are no longer part of the layout.
        for peer in Array(peers.values) {
            if let name = peer.name, newConfig.screen(named: name) == nil {
                log("\(name) removed from layout, disconnecting")
                disconnect(peer, sending: .unknownClient)
            } else if let name = peer.name {
                send(.resetOptions, to: peer)
                send(.setOptions(config.clientOptions(for: name)), to: peer)
            }
        }
    }

    // MARK: - Network

    public func connectionOpened(_ id: ConnectionID, address: String) {
        let peer = Peer(id: id, address: address, now: clock())
        peers[id] = peer
        send(.hello(protocolName: "Barrier", major: Message.protocolMajor, minor: Message.protocolMinor), to: peer)
    }

    public func connection(_ id: ConnectionID, didReceive data: Data) {
        guard let peer = peers[id] else { return }
        peer.lastReceived = clock()
        do {
            for frame in try peer.decoder.feed(data) {
                try handle(try MessageCodec.decode(frame), from: peer)
                if peers[id] == nil { return }
            }
        } catch {
            log("protocol error from \(peer.name ?? peer.address): \(error)")
            disconnect(peer, sending: .bad)
        }
    }

    public func connectionClosed(_ id: ConnectionID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        forget(peer)
    }

    /// Call about once a second: sends keep-alives and drops dead connections.
    public func tick() {
        let now = clock()
        let rate = Double(max(config.options.heartbeat, 500)) / 1000
        for peer in Array(peers.values) {
            if peer.name == nil {
                if now - peer.openedAt > 30 {
                    log("\(peer.address) did not complete the handshake")
                    disconnect(peer, sending: nil)
                }
                continue
            }
            if now - peer.lastReceived > rate * 3 {
                log("\(peer.name!) timed out")
                disconnect(peer, sending: nil)
                continue
            }
            if now - peer.lastSent >= rate { send(.keepAlive, to: peer) }
        }
    }

    private func handle(_ msg: Message, from peer: Peer) throws {
        if peer.name == nil {
            guard case let .helloBack(_, major, minor, rawName) = msg else {
                throw ProtocolError.invalid("expected hello back, got \(msg)")
            }
            if major != Message.protocolMajor || minor < Message.protocolMinor {
                log("\(rawName) uses incompatible protocol \(major).\(minor)")
                disconnect(peer, sending: .incompatible(major: Message.protocolMajor, minor: Message.protocolMinor))
                return
            }
            guard let name = config.canonicalName(rawName), name != primaryName else {
                log("refused unknown screen \"\(rawName)\" from \(peer.address); add it to the layout")
                disconnect(peer, sending: .unknownClient)
                return
            }
            if byName[name] != nil {
                log("refused \"\(name)\": already connected")
                disconnect(peer, sending: .busy)
                return
            }
            peer.name = name
            byName[name] = peer.id
            log("\(name) connected from \(peer.address)")
            send(.queryInfo, to: peer)
            send(.resetOptions, to: peer)
            send(.setOptions(config.clientOptions(for: name)), to: peer)
            if clipboard != nil, config.options.clipboardSharing, clipboardOwner != name {
                // Let the new client know someone else owns the clipboard.
                send(.grabClipboard(id: 0, sequence: 0), to: peer)
            }
            delegate?.engineStateDidChange(self)
            return
        }

        switch msg {
        case let .info(x, y, width, height, _, _, _):
            peer.shape = Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
            send(.infoAck, to: peer)
            if activeScreen == peer.name, let shape = peer.shape { cursor = shape.clamp(cursor) }
            delegate?.engineStateDidChange(self)
        case .keepAlive, .noOp:
            break
        case let .grabClipboard(id, seq):
            guard id == 0, config.options.clipboardSharing, let name = peer.name else { break }
            if seq >= clipboardSequence {
                clipboardOwner = name
                clipboardSequence = seq
                for other in peers.values where other !== peer && other.name != nil {
                    send(.grabClipboard(id: 0, sequence: 0), to: other)
                }
            }
        case let .clipboardChunk(id, _, mark, data):
            guard let complete = try peer.assembler.add(id: id, mark: mark, data: data) else { break }
            guard id == 0, config.options.clipboardSharing, peer.name == clipboardOwner else { break }
            let content = try ClipboardContent.unmarshal(complete)
            if content == clipboard { break }
            clipboard = content
            log("clipboard updated by \(peer.name ?? "?")")
            for other in peers.values where other !== peer { other.clipboardDirty = true }
            delegate?.engine(self, setPrimaryClipboard: content)
            if let active = activePeer, active !== peer { sendClipboardIfDirty(to: active) }
        case .close:
            disconnect(peer, sending: nil)
        default:
            // Clients do not send anything else in protocol 1.6.
            break
        }
    }

    // MARK: - Input from the primary screen. Return value: true = swallow the local event.

    /// Mouse moved on the primary. `location` is where the system put the cursor
    /// (global coordinates), `dx`/`dy` the raw motion.
    public func mouseMoved(location: Point, dx: Double, dy: Double) -> Bool {
        if isPrimaryActive {
            primaryMoved(location, dx, dy)
            return !isPrimaryActive
        }
        guard let peer = activePeer, let shape = peer.shape else {
            returnToPrimary(at: layout.bounds.center)
            return true
        }
        fractional.x += dx
        fractional.y += dy
        let mx = fractional.x.rounded(.towardZero), my = fractional.y.rounded(.towardZero)
        fractional.x -= mx
        fractional.y -= my
        if mx == 0 && my == 0 { return true }

        let next = Point(x: cursor.x + mx, y: cursor.y + my)
        var leaving: Direction?
        if next.x < shape.minX { leaving = .left }
        else if next.x > shape.maxX - 1 { leaving = .right }
        else if next.y < shape.minY { leaving = .top }
        else if next.y > shape.maxY - 1 { leaving = .bottom }

        if let dir = leaving, canSwitch(), switchDelayElapsed() {
            let t = dir.fraction(of: shape.clamp(next), in: shape)
            if let n = config.neighbor(of: peer.name!, direction: dir, at: t), switchScreen(to: n.name, direction: dir, t: n.t) {
                return true
            }
        }
        if leaving == nil { edgePushStart = nil }

        let clamped = shape.clamp(next)
        let delta = (Int(clamped.x - cursor.x), Int(clamped.y - cursor.y))
        cursor = clamped
        if config.options.relativeMouseMoves {
            if delta != (0, 0) { send(.mouseRelMove(dx: delta.0, dy: delta.1), to: peer) }
        } else {
            send(.mouseMove(x: Int(cursor.x), y: Int(cursor.y)), to: peer)
        }
        return true
    }

    public func mouseButton(_ button: Int, down: Bool) -> Bool {
        if isPrimaryActive {
            if down { primaryButtons.insert(button) } else { primaryButtons.remove(button) }
            return false
        }
        guard let peer = activePeer else { return true }
        if down {
            peer.pressedButtons.insert(button)
            send(.mouseDown(button: button), to: peer)
        } else {
            peer.pressedButtons.remove(button)
            send(.mouseUp(button: button), to: peer)
        }
        return true
    }

    /// Wheel motion in Barrier units (+120 = one notch up/right).
    public func mouseWheel(dx: Int, dy: Int) -> Bool {
        guard !isPrimaryActive else { return false }
        if let peer = activePeer, dx != 0 || dy != 0 {
            send(.mouseWheel(xDelta: clamp16(dx), yDelta: clamp16(dy)), to: peer)
        }
        return true
    }

    public enum KeyAction { case down, up, `repeat` }

    public func key(_ action: KeyAction, keyID: Int, modifiers: Int, button: Int) -> Bool {
        toggles = modifiers & KeyModifiers.toggles.rawValue
        guard !isPrimaryActive else { return false }
        guard let peer = activePeer else { return true }
        switch action {
        case .down:
            peer.pressedKeys[button] = (keyID, modifiers)
            send(.keyDown(keyID: keyID, modifiers: modifiers, button: button), to: peer)
        case .repeat:
            send(.keyRepeat(keyID: keyID, modifiers: modifiers, count: 1, button: button), to: peer)
        case .up:
            let id = peer.pressedKeys.removeValue(forKey: button)?.keyID ?? keyID
            send(.keyUp(keyID: id, modifiers: modifiers, button: button), to: peer)
        }
        return true
    }

    /// The primary's clipboard changed (by the user, not by `setPrimaryClipboard`).
    public func primaryClipboardChanged(_ content: ClipboardContent) {
        guard config.options.clipboardSharing, content != clipboard else { return }
        clipboard = content
        clipboardOwner = primaryName
        for peer in peers.values where peer.name != nil {
            peer.clipboardDirty = true
            send(.grabClipboard(id: 0, sequence: 0), to: peer)
        }
        if let active = activePeer { sendClipboardIfDirty(to: active) }
    }

    /// Brings the cursor back to the primary screen (hotkey or emergency).
    public func returnToPrimary() {
        guard !isPrimaryActive else { return }
        returnToPrimary(at: layout.bounds.center)
    }

    /// Moves the cursor to the named client's centre, if connected.
    @discardableResult
    public func jump(to name: String) -> Bool {
        guard let canonical = config.canonicalName(name) else { return false }
        if canonical == primaryName {
            returnToPrimary()
            return true
        }
        guard let id = byName[canonical], let shape = peers[id]?.shape else { return false }
        let wasPrimary = isPrimaryActive
        leaveActiveClient()
        enterClient(canonical, at: shape.center)
        if wasPrimary { delegate?.engineDidLeavePrimary(self) }
        delegate?.engineStateDidChange(self)
        return true
    }

    public func shutdown() {
        returnToPrimary()
        for peer in Array(peers.values) { disconnect(peer, sending: .close) }
    }

    // MARK: - Switching

    private var activePeer: Peer? {
        guard !isPrimaryActive, let id = byName[activeScreen] else { return nil }
        return peers[id]
    }

    private func primaryMoved(_ p: Point, _ dx: Double, _ dy: Double) {
        var dir: Direction?
        if dx < 0 && layout.isAtOuterEdge(p, .left) { dir = .left }
        else if dx > 0 && layout.isAtOuterEdge(p, .right) { dir = .right }
        else if dy < 0 && layout.isAtOuterEdge(p, .top) { dir = .top }
        else if dy > 0 && layout.isAtOuterEdge(p, .bottom) { dir = .bottom }
        guard let dir else {
            edgePushStart = nil
            return
        }
        guard canSwitch() else { return }
        let t = dir.fraction(of: p, in: layout.bounds)
        guard let n = config.neighbor(of: primaryName, direction: dir, at: t), n.name != primaryName else { return }
        guard let id = byName[n.name], peers[id]?.shape != nil else { return }
        guard switchDelayElapsed() else { return }
        _ = switchScreen(to: n.name, direction: dir, t: n.t)
    }

    private func canSwitch() -> Bool {
        if isPrimaryActive { return primaryButtons.isEmpty }
        return activePeer?.pressedButtons.isEmpty ?? true
    }

    private func switchDelayElapsed() -> Bool {
        let delay = Double(config.options.switchDelay) / 1000
        guard delay > 0 else { return true }
        let now = clock()
        guard let start = edgePushStart else {
            edgePushStart = now
            return false
        }
        return now - start >= delay
    }

    /// Switches to `target`, entering it while moving in `direction` at edge fraction `t`.
    private func switchScreen(to target: String, direction: Direction, t: Double) -> Bool {
        edgePushStart = nil
        if target == primaryName {
            let entry = direction.entryPoint(into: layout.bounds, at: t)
            returnToPrimary(at: layout.nearestPoint(to: entry))
            return true
        }
        guard let id = byName[target], let shape = peers[id]?.shape else { return false }
        let wasPrimary = isPrimaryActive
        leaveActiveClient()
        enterClient(target, at: direction.entryPoint(into: shape, at: t))
        if wasPrimary { delegate?.engineDidLeavePrimary(self) }
        delegate?.engineStateDidChange(self)
        return true
    }

    private func enterClient(_ name: String, at point: Point) {
        guard let id = byName[name], let peer = peers[id] else { return }
        sequence = (sequence + 1) & 0x7fff_ffff
        activeScreen = name
        cursor = point
        fractional = Point(x: 0, y: 0)
        log("switched to \(name)")
        send(.enter(x: Int(point.x), y: Int(point.y), sequence: sequence, modifiers: toggles), to: peer)
        sendClipboardIfDirty(to: peer)
    }

    private func leaveActiveClient() {
        guard let peer = activePeer else { return }
        // Release anything still held so the client does not see stuck keys or buttons.
        for (button, key) in peer.pressedKeys {
            send(.keyUp(keyID: key.keyID, modifiers: key.modifiers, button: button), to: peer)
        }
        peer.pressedKeys = [:]
        for b in peer.pressedButtons { send(.mouseUp(button: b), to: peer) }
        peer.pressedButtons = []
        send(.leave, to: peer)
    }

    private func returnToPrimary(at point: Point) {
        leaveActiveClient()
        activeScreen = primaryName
        log("switched to \(primaryName)")
        delegate?.engine(self, didEnterPrimaryAt: point)
        delegate?.engineStateDidChange(self)
    }

    private func sendClipboardIfDirty(to peer: Peer) {
        guard config.options.clipboardSharing, peer.clipboardDirty, let clipboard, !clipboard.isEmpty else { return }
        peer.clipboardDirty = false
        for msg in ClipboardChunks.split(id: 0, sequence: 0, data: clipboard.marshal()) { send(msg, to: peer) }
    }

    // MARK: - Helpers

    private func send(_ msg: Message, to peer: Peer) {
        peer.lastSent = clock()
        delegate?.engine(self, send: Framing.frame(msg), to: peer.id)
    }

    private func disconnect(_ peer: Peer, sending msg: Message?) {
        if let msg { send(msg, to: peer) }
        peers.removeValue(forKey: peer.id)
        forget(peer)
        delegate?.engine(self, close: peer.id)
    }

    private func forget(_ peer: Peer) {
        guard let name = peer.name else { return }
        if byName[name] == peer.id { byName[name] = nil }
        log("\(name) disconnected")
        if activeScreen == name {
            activeScreen = primaryName
            delegate?.engine(self, didEnterPrimaryAt: layout.bounds.center)
        }
        if clipboardOwner == name { clipboardOwner = primaryName }
        delegate?.engineStateDidChange(self)
    }

    private func log(_ s: String) { delegate?.engine(self, log: s) }

    private func clamp16(_ v: Int) -> Int { min(max(v, -32768), 32767) }
}
