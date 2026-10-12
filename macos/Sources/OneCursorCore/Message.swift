import Foundation

/// Messages of the Barrier/Synergy 1.6 protocol (the frame payload; see `Framing`).
///
/// Positions and sizes are signed 16 bit, key ids/modifier masks/key buttons
/// unsigned 16 bit and sequence numbers unsigned 32 bit.
public enum Message: Equatable {
    // handshake
    case hello(protocolName: String, major: Int, minor: Int)
    case helloBack(protocolName: String, major: Int, minor: Int, name: String)
    // commands
    case noOp
    case close
    case enter(x: Int, y: Int, sequence: Int, modifiers: Int)
    case leave
    case grabClipboard(id: Int, sequence: Int)
    case screenSaver(on: Bool)
    case resetOptions
    case infoAck
    case keepAlive
    // data
    case keyDown(keyID: Int, modifiers: Int, button: Int)
    case keyRepeat(keyID: Int, modifiers: Int, count: Int, button: Int)
    case keyUp(keyID: Int, modifiers: Int, button: Int)
    case mouseDown(button: Int)
    case mouseUp(button: Int)
    case mouseMove(x: Int, y: Int)
    case mouseRelMove(dx: Int, dy: Int)
    case mouseWheel(xDelta: Int, yDelta: Int)
    case clipboardChunk(id: Int, sequence: Int, mark: Int, data: Data)
    case info(x: Int, y: Int, width: Int, height: Int, warpSize: Int, mouseX: Int, mouseY: Int)
    case setOptions([Int])
    case queryInfo
    // errors
    case incompatible(major: Int, minor: Int)
    case busy
    case unknownClient
    case bad
    /// A well-formed message this implementation does not interpret.
    case unsupported(code: String, payload: Data)

    public static let protocolMajor = 1
    public static let protocolMinor = 6
    public static let defaultPort = 24800
    public static let protocolNames = ["Barrier", "Synergy"]
}

public enum MessageCodec {
    public static func encode(_ msg: Message) -> Data {
        var w = ByteWriter()
        switch msg {
        case let .hello(name, major, minor):
            w.ascii(name); w.u16(major); w.u16(minor)
        case let .helloBack(name, major, minor, client):
            w.ascii(name); w.u16(major); w.u16(minor); w.string(client)
        case .noOp: w.ascii("CNOP")
        case .close: w.ascii("CBYE")
        case let .enter(x, y, seq, mods):
            w.ascii("CINN"); w.u16(x); w.u16(y); w.u32(seq); w.u16(mods)
        case .leave: w.ascii("COUT")
        case let .grabClipboard(id, seq):
            w.ascii("CCLP"); w.u8(id); w.u32(seq)
        case let .screenSaver(on):
            w.ascii("CSEC"); w.u8(on ? 1 : 0)
        case .resetOptions: w.ascii("CROP")
        case .infoAck: w.ascii("CIAK")
        case .keepAlive: w.ascii("CALV")
        case let .keyDown(id, mods, button):
            w.ascii("DKDN"); w.u16(id); w.u16(mods); w.u16(button)
        case let .keyRepeat(id, mods, count, button):
            w.ascii("DKRP"); w.u16(id); w.u16(mods); w.u16(count); w.u16(button)
        case let .keyUp(id, mods, button):
            w.ascii("DKUP"); w.u16(id); w.u16(mods); w.u16(button)
        case let .mouseDown(button):
            w.ascii("DMDN"); w.u8(button)
        case let .mouseUp(button):
            w.ascii("DMUP"); w.u8(button)
        case let .mouseMove(x, y):
            w.ascii("DMMV"); w.u16(x); w.u16(y)
        case let .mouseRelMove(dx, dy):
            w.ascii("DMRM"); w.u16(dx); w.u16(dy)
        case let .mouseWheel(xd, yd):
            w.ascii("DMWM"); w.u16(xd); w.u16(yd)
        case let .clipboardChunk(id, seq, mark, data):
            w.ascii("DCLP"); w.u8(id); w.u32(seq); w.u8(mark); w.string(data)
        case let .info(x, y, width, height, warp, mx, my):
            w.ascii("DINF"); w.u16(x); w.u16(y); w.u16(width); w.u16(height); w.u16(warp); w.u16(mx); w.u16(my)
        case let .setOptions(values):
            w.ascii("DSOP"); w.intList(values)
        case .queryInfo: w.ascii("QINF")
        case let .incompatible(major, minor):
            w.ascii("EICV"); w.u16(major); w.u16(minor)
        case .busy: w.ascii("EBSY")
        case .unknownClient: w.ascii("EUNK")
        case .bad: w.ascii("EBAD")
        case let .unsupported(code, payload):
            w.ascii(code); w.raw(payload)
        }
        return w.data
    }

    public static func decode(_ frame: Data) throws -> Message {
        let bytes = [UInt8](frame)
        for name in Message.protocolNames where bytes.starts(with: Array(name.utf8)) {
            var r = ByteReader(frame, offset: name.utf8.count)
            let major = try r.s16()
            let minor = try r.s16()
            if r.remaining == 0 { return .hello(protocolName: name, major: major, minor: minor) }
            let client = String(decoding: try r.string(), as: UTF8.self)
            return .helloBack(protocolName: name, major: major, minor: minor, name: client)
        }
        guard bytes.count >= 4 else { throw ProtocolError.invalid("message too short (\(bytes.count) bytes)") }
        let code = String(decoding: bytes[0..<4], as: UTF8.self)
        var r = ByteReader(frame, offset: 4)
        let payload = bytes.count - 4
        switch code {
        case "CNOP": return .noOp
        case "CBYE": return .close
        case "CINN": return try .enter(x: r.s16(), y: r.s16(), sequence: r.u32(), modifiers: r.u16())
        case "COUT": return .leave
        case "CCLP": return try .grabClipboard(id: r.u8(), sequence: r.u32())
        case "CSEC": return try .screenSaver(on: r.u8() != 0)
        case "CROP": return .resetOptions
        case "CIAK": return .infoAck
        case "CALV": return .keepAlive
        case "DKDN":
            return try .keyDown(keyID: r.u16(), modifiers: r.u16(), button: payload >= 6 ? r.u16() : 0)
        case "DKRP":
            return try .keyRepeat(keyID: r.u16(), modifiers: r.u16(), count: r.u16(),
                              button: payload >= 8 ? r.u16() : 0)
        case "DKUP":
            return try .keyUp(keyID: r.u16(), modifiers: r.u16(), button: payload >= 6 ? r.u16() : 0)
        case "DMDN": return try .mouseDown(button: r.u8())
        case "DMUP": return try .mouseUp(button: r.u8())
        case "DMMV": return try .mouseMove(x: r.s16(), y: r.s16())
        case "DMRM": return try .mouseRelMove(dx: r.s16(), dy: r.s16())
        case "DMWM":
            if payload >= 4 { return try .mouseWheel(xDelta: r.s16(), yDelta: r.s16()) }
            return try .mouseWheel(xDelta: 0, yDelta: r.s16())
        case "DCLP":
            return try .clipboardChunk(id: r.u8(), sequence: r.u32(), mark: r.u8(), data: r.string())
        case "DINF":
            return try .info(x: r.s16(), y: r.s16(), width: r.s16(), height: r.s16(),
                         warpSize: r.s16(), mouseX: r.s16(), mouseY: r.s16())
        case "DSOP": return try .setOptions(r.intList())
        case "QINF": return .queryInfo
        case "EICV": return try .incompatible(major: r.s16(), minor: r.s16())
        case "EBSY": return .busy
        case "EUNK": return .unknownClient
        case "EBAD": return .bad
        default:
            guard code.allSatisfy({ $0 >= "A" && $0 <= "Z" }) else { throw ProtocolError.invalid("invalid message code") }
            return .unsupported(code: code, payload: try r.raw(r.remaining))
        }
    }
}

/// Barrier's packet framing: each message is preceded by its 4 byte big-endian length.
public enum Framing {
    public static let maxMessageLength = 4 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var w = ByteWriter()
        w.u32(payload.count)
        w.raw(payload)
        return w.data
    }

    public static func frame(_ msg: Message) -> Data { frame(MessageCodec.encode(msg)) }
}

/// Incremental frame decoder for stream transports.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    /// Appends `data` and returns every frame that is now complete.
    public mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        var pos = buffer.startIndex
        while buffer.endIndex - pos >= 4 {
            let len = Int(buffer[pos]) << 24 | Int(buffer[pos + 1]) << 16 | Int(buffer[pos + 2]) << 8 | Int(buffer[pos + 3])
            if len > Framing.maxMessageLength { throw ProtocolError.invalid("invalid frame length \(len)") }
            guard buffer.endIndex - pos - 4 >= len else { break }
            frames.append(Data(buffer[(pos + 4)..<(pos + 4 + len)]))
            pos += 4 + len
        }
        buffer = Data(buffer[pos...])
        return frames
    }
}
