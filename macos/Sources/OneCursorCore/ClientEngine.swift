import Foundation

/// Platform hooks for `ClientEngine`, called on the engine's queue.
public protocol ClientEngineDelegate: AnyObject {
    func clientEngine(_ engine: ClientEngine, send data: Data)
    /// The engine wants the connection closed (error or server request).
    func clientEngine(_ engine: ClientEngine, disconnectWithReason reason: String)
    func clientEngineDidConnect(_ engine: ClientEngine, serverProtocol: String)
    func clientEngineScreenShape(_ engine: ClientEngine) -> Rect
    func clientEngineCursorPosition(_ engine: ClientEngine) -> Point

    func clientEngine(_ engine: ClientEngine, enterAt point: Point, modifiers: Int)
    func clientEngineLeave(_ engine: ClientEngine)
    func clientEngine(_ engine: ClientEngine, mouseMoveTo point: Point)
    func clientEngine(_ engine: ClientEngine, mouseMoveBy dx: Int, _ dy: Int)
    func clientEngine(_ engine: ClientEngine, mouseButton button: Int, down: Bool)
    func clientEngine(_ engine: ClientEngine, wheel dx: Int, _ dy: Int)
    func clientEngine(_ engine: ClientEngine, key keyID: Int, modifiers: Int, button: Int, action: ServerEngine.KeyAction, count: Int)
    func clientEngine(_ engine: ClientEngine, clipboard content: ClipboardContent)
}

/// Barrier protocol 1.6 client logic, independent of the transport.
public final class ClientEngine {
    public weak var delegate: ClientEngineDelegate?
    public let name: String
    public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var decoder = FrameDecoder()
    private var assembler = ClipboardAssembler()
    private var modifiers = ModifierTranslator()
    private var handshakeDone = false
    private var ignoreMouse = false
    private var sequence = 0
    private var keepAliveRate: TimeInterval = 3
    private var lastReceived: TimeInterval = 0
    public private(set) var isActive = false

    public init(name: String) {
        self.name = name
    }

    public func connected() {
        lastReceived = clock()
    }

    public func receive(_ data: Data) {
        lastReceived = clock()
        do {
            for frame in try decoder.feed(data) {
                if let reason = try handle(MessageCodec.decode(frame)) {
                    delegate?.clientEngine(self, disconnectWithReason: reason)
                    return
                }
            }
        } catch {
            send(.bad)
            delegate?.clientEngine(self, disconnectWithReason: "protocol error: \(error)")
        }
    }

    /// Call about once a second to detect a dead server.
    public func tick() {
        if clock() - lastReceived > keepAliveRate * 3 {
            delegate?.clientEngine(self, disconnectWithReason: "server did not respond")
        }
    }

    /// Re-sends the screen shape after a display change.
    public func screenChanged() {
        guard handshakeDone else { return }
        ignoreMouse = true
        sendInfo()
    }

    public func sendClipboard(_ content: ClipboardContent) {
        guard handshakeDone else { return }
        send(.grabClipboard(id: 0, sequence: sequence))
        for msg in ClipboardChunks.split(id: 0, sequence: sequence, data: content.marshal()) { send(msg) }
    }

    /// Handles one message; returns a reason when the connection must end.
    private func handle(_ msg: Message) throws -> String? {
        switch msg {
        case let .hello(proto, major, minor):
            if major < Message.protocolMajor || (major == Message.protocolMajor && minor < Message.protocolMinor) {
                return "server protocol \(major).\(minor) is too old"
            }
            send(.helloBack(protocolName: proto, major: Message.protocolMajor, minor: Message.protocolMinor, name: name))
            handshakeDone = true
            delegate?.clientEngineDidConnect(self, serverProtocol: "\(proto) \(major).\(minor)")
        case .queryInfo: sendInfo()
        case .infoAck: ignoreMouse = false
        case .resetOptions:
            modifiers.reset()
            keepAliveRate = 3
        case let .setOptions(list):
            var i = 0
            while i + 1 < list.count {
                let id = list[i], value = list[i + 1]
                if id == OptionID.heartbeat { keepAliveRate = value > 0 ? Double(value) / 1000 : 3 }
                for mod in ModifierID.allCases where mod.optionID == id {
                    modifiers.map(mod, to: ModifierID(rawValue: value) ?? mod)
                }
                i += 2
            }
        case .keepAlive: send(.keepAlive)
        case .noOp: break
        case let .enter(x, y, seq, mods):
            sequence = seq
            isActive = true
            delegate?.clientEngine(self, enterAt: Point(x: Double(x), y: Double(y)), modifiers: modifiers.translateMask(mods))
        case .leave:
            isActive = false
            delegate?.clientEngineLeave(self)
        case let .mouseMove(x, y):
            if !ignoreMouse { delegate?.clientEngine(self, mouseMoveTo: Point(x: Double(x), y: Double(y))) }
        case let .mouseRelMove(dx, dy):
            if !ignoreMouse { delegate?.clientEngine(self, mouseMoveBy: dx, dy) }
        case let .mouseDown(b): delegate?.clientEngine(self, mouseButton: b, down: true)
        case let .mouseUp(b): delegate?.clientEngine(self, mouseButton: b, down: false)
        case let .mouseWheel(dx, dy): delegate?.clientEngine(self, wheel: dx, dy)
        case let .keyDown(id, mods, button):
            delegate?.clientEngine(self, key: modifiers.translateKey(id), modifiers: modifiers.translateMask(mods),
                                   button: button, action: .down, count: 1)
        case let .keyRepeat(id, mods, count, button):
            delegate?.clientEngine(self, key: modifiers.translateKey(id), modifiers: modifiers.translateMask(mods),
                                   button: button, action: .repeat, count: count)
        case let .keyUp(id, mods, button):
            delegate?.clientEngine(self, key: modifiers.translateKey(id), modifiers: modifiers.translateMask(mods),
                                   button: button, action: .up, count: 1)
        case let .clipboardChunk(id, _, mark, data):
            if let complete = try assembler.add(id: id, mark: mark, data: data), id == 0 {
                delegate?.clientEngine(self, clipboard: try ClipboardContent.unmarshal(complete))
            }
        case .grabClipboard, .screenSaver, .unsupported: break
        case .close: return "server closed the connection"
        case let .incompatible(major, minor): return "server has incompatible version \(major).\(minor)"
        case .busy: return "server already has a connected client named \"\(name)\""
        case .unknownClient: return "server refused client name \"\(name)\" (add it to the server's layout)"
        case .bad: return "server reported a protocol error"
        case .helloBack, .info: throw ProtocolError.invalid("unexpected message \(msg)")
        }
        return nil
    }

    private func sendInfo() {
        guard let d = delegate else { return }
        let s = d.clientEngineScreenShape(self)
        let p = d.clientEngineCursorPosition(self)
        send(.info(x: Int(s.x), y: Int(s.y), width: Int(s.width), height: Int(s.height), warpSize: 0,
                   mouseX: Int(p.x), mouseY: Int(p.y)))
    }

    private func send(_ msg: Message) {
        delegate?.clientEngine(self, send: Framing.frame(msg))
    }
}
