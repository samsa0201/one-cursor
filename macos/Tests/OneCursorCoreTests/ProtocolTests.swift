import XCTest
@testable import OneCursorCore

final class ProtocolTests: XCTestCase {
    func roundTrip(_ msg: Message, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try MessageCodec.decode(MessageCodec.encode(msg)), msg, file: file, line: line)
    }

    func testAllMessagesRoundTrip() throws {
        let messages: [Message] = [
            .hello(protocolName: "Barrier", major: 1, minor: 6),
            .hello(protocolName: "Synergy", major: 1, minor: 6),
            .helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "pixel"),
            .noOp, .close, .leave, .resetOptions, .infoAck, .keepAlive, .queryInfo, .busy, .unknownClient, .bad,
            .enter(x: -5, y: 1079, sequence: 0x7fff_ffff, modifiers: KeyModifiers.capsLock.rawValue),
            .grabClipboard(id: 1, sequence: 42),
            .screenSaver(on: true),
            .keyDown(keyID: 0x61, modifiers: 1, button: 1),
            .keyRepeat(keyID: KeyID.backSpace, modifiers: 0, count: 3, button: 52),
            .keyUp(keyID: KeyID.superL, modifiers: KeyModifiers.superKey.rawValue, button: 56),
            .mouseDown(button: 1), .mouseUp(button: 3),
            .mouseMove(x: -32768, y: 32767),
            .mouseRelMove(dx: -3, dy: 4),
            .mouseWheel(xDelta: 0, yDelta: -120),
            .clipboardChunk(id: 0, sequence: 7, mark: 2, data: Data("xin chào".utf8)),
            .info(x: 0, y: 0, width: 1080, height: 2400, warpSize: 0, mouseX: 540, mouseY: 1200),
            .setOptions([OptionID.heartbeat, 5000, OptionID.code("MMFR"), 2]),
            .incompatible(major: 1, minor: 6),
        ]
        for m in messages { try roundTrip(m) }
    }

    /// Byte layouts shared with the Kotlin implementation's tests.
    func testGoldenBytes() {
        XCTAssertEqual([UInt8](Framing.frame(.hello(protocolName: "Barrier", major: 1, minor: 6))),
                       [0, 0, 0, 11] + Array("Barrier".utf8) + [0, 1, 0, 6])
        XCTAssertEqual([UInt8](MessageCodec.encode(.helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "tab"))),
                       Array("Barrier".utf8) + [0, 1, 0, 6, 0, 0, 0, 3] + Array("tab".utf8))
        XCTAssertEqual([UInt8](MessageCodec.encode(.mouseMove(x: -2, y: 256))), Array("DMMV".utf8) + [0xff, 0xfe, 0x01, 0x00])
        XCTAssertEqual(OptionID.heartbeat, 0x4841_5254)
    }

    func testProtocol10Variants() throws {
        XCTAssertEqual(try MessageCodec.decode(Data("DMWM".utf8) + Data([0, 120])), .mouseWheel(xDelta: 0, yDelta: 120))
        XCTAssertEqual(try MessageCodec.decode(Data("DKDN".utf8) + Data([0, 0x61, 0, 1])), .keyDown(keyID: 0x61, modifiers: 1, button: 0))
    }

    func testFrameDecoderSplitInput() throws {
        let all = Framing.frame(.keepAlive) + Framing.frame(.mouseMove(x: 10, y: 20))
        var dec = FrameDecoder()
        var msgs: [Message] = []
        for b in all {
            for f in try dec.feed(Data([b])) { msgs.append(try MessageCodec.decode(f)) }
        }
        XCTAssertEqual(msgs, [.keepAlive, .mouseMove(x: 10, y: 20)])
    }

    func testClipboardMarshalAndChunks() throws {
        let c = ClipboardContent(text: "Xin chào\r\nthế giới", html: "<b>hi</b>")
        let back = try ClipboardContent.unmarshal(c.marshal())
        XCTAssertEqual(back.text, "Xin chào\nthế giới")
        XCTAssertEqual(back.html, "<b>hi</b>")
        XCTAssertEqual([UInt8](ClipboardContent(text: "hi").marshal()), [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 104, 105])

        let data = Data((0..<(ClipboardChunks.chunkSize * 2 + 100)).map { UInt8($0 % 251) })
        let msgs = ClipboardChunks.split(id: 0, sequence: 9, data: data)
        XCTAssertEqual(msgs.count, 5)
        var asm = ClipboardAssembler()
        var result: Data?
        for m in msgs {
            guard case let .clipboardChunk(id, _, mark, d) = m else { return XCTFail() }
            result = try asm.add(id: id, mark: mark, data: d)
        }
        XCTAssertEqual(result, data)
    }

    func testModifierTranslator() {
        var t = ModifierTranslator()
        t.map(.superKey, to: .control)
        XCTAssertEqual(t.translateKey(KeyID.superR), KeyID.controlR)
        XCTAssertEqual(t.translateMask(KeyModifiers.superKey.rawValue | KeyModifiers.capsLock.rawValue),
                       KeyModifiers.control.rawValue | KeyModifiers.capsLock.rawValue)
        XCTAssertEqual(t.translateKey(0x63), 0x63)
    }
}
