import XCTest
@testable import OneCursorCore

/// Drives `ServerEngine` with a fake client connection and fake displays.
final class ServerEngineTests: XCTestCase {
    final class Recorder: ServerEngineDelegate {
        var sent: [ConnectionID: [Message]] = [:]
        var decoders: [ConnectionID: FrameDecoder] = [:]
        var closed: [ConnectionID] = []
        var leftPrimary = 0
        var enteredPrimary: [Point] = []
        var clipboards: [ClipboardContent] = []

        func engine(_ engine: ServerEngine, send data: Data, to connection: ConnectionID) {
            var d = decoders[connection] ?? FrameDecoder()
            for f in try! d.feed(data) { sent[connection, default: []].append(try! MessageCodec.decode(f)) }
            decoders[connection] = d
        }
        func engine(_ engine: ServerEngine, close connection: ConnectionID) { closed.append(connection) }
        func engineDidLeavePrimary(_ engine: ServerEngine) { leftPrimary += 1 }
        func engine(_ engine: ServerEngine, didEnterPrimaryAt point: Point) { enteredPrimary.append(point) }
        func engine(_ engine: ServerEngine, setPrimaryClipboard content: ClipboardContent) { clipboards.append(content) }

        func take(_ id: ConnectionID) -> [Message] {
            defer { sent[id] = [] }
            return sent[id] ?? []
        }
    }

    var now: TimeInterval = 1000
    var engine: ServerEngine!
    var rec: Recorder!

    override func setUp() {
        let config = ScreenConfig.simple(server: "mac", clients: [("phone", .right), ("pc", .left)])
        // Two displays side by side; the right one is smaller and lower.
        let layout = DisplayLayout([Rect(x: 0, y: 0, width: 1440, height: 900), Rect(x: 1440, y: 100, width: 1280, height: 720)])
        engine = ServerEngine(primaryName: "mac", config: config, layout: layout)
        engine.clock = { [unowned self] in self.now }
        rec = Recorder()
        engine.delegate = rec
    }

    func feed(_ id: ConnectionID, _ msgs: Message...) {
        engine.connection(id, didReceive: msgs.reduce(Data()) { $0 + Framing.frame($1) })
    }

    func connectPhone(id: ConnectionID = 1) {
        engine.connectionOpened(id, address: "10.0.0.2")
        XCTAssertEqual(rec.take(id), [.hello(protocolName: "Barrier", major: 1, minor: 6)])
        feed(id, .helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "Phone"))
        XCTAssertEqual(rec.take(id), [.queryInfo, .resetOptions, .setOptions([])])
        feed(id, .info(x: 0, y: 0, width: 720, height: 1600, warpSize: 0, mouseX: 0, mouseY: 0))
        XCTAssertEqual(rec.take(id), [.infoAck])
    }

    func testHandshakeAndSwitchRightAndBack() {
        connectPhone()
        XCTAssertEqual(engine.clients.map(\.name), ["phone"])

        // Moving inside the primary does nothing.
        XCTAssertFalse(engine.mouseMoved(location: Point(x: 700, y: 400), dx: 5, dy: 0))
        // The right edge of the left display is not an outer edge (another display continues there).
        XCTAssertFalse(engine.mouseMoved(location: Point(x: 1439, y: 400), dx: 5, dy: 0))
        XCTAssertTrue(engine.isPrimaryActive)
        // The right edge of the right display is.
        XCTAssertTrue(engine.mouseMoved(location: Point(x: 2719, y: 100), dx: 5, dy: 0))
        XCTAssertEqual(engine.activeScreen, "phone")
        XCTAssertEqual(rec.leftPrimary, 1)
        // Entered at the phone's left edge, at the same fraction of the height (100/899 of the union).
        XCTAssertEqual(rec.take(1), [.enter(x: 1, y: 178, sequence: 1, modifiers: 0)])

        XCTAssertTrue(engine.mouseMoved(location: Point(x: 0, y: 0), dx: 10, dy: 20))
        XCTAssertEqual(rec.take(1), [.mouseMove(x: 11, y: 198)])

        XCTAssertTrue(engine.mouseButton(1, down: true))
        XCTAssertTrue(engine.mouseWheel(dx: 0, dy: 120))
        XCTAssertTrue(engine.key(.down, keyID: 0x61, modifiers: 0, button: 1))
        XCTAssertEqual(rec.take(1), [.mouseDown(button: 1), .mouseWheel(xDelta: 0, yDelta: 120), .keyDown(keyID: 0x61, modifiers: 0, button: 1)])

        // Cannot leave while a button is held.
        XCTAssertTrue(engine.mouseMoved(location: Point(x: 0, y: 0), dx: -100, dy: 0))
        XCTAssertEqual(engine.activeScreen, "phone")
        XCTAssertEqual(rec.take(1), [.mouseMove(x: 0, y: 198)])
        _ = engine.mouseButton(1, down: false)
        _ = rec.take(1)

        // Leaving the phone's left edge returns to the mac's right edge, releasing held keys.
        XCTAssertTrue(engine.mouseMoved(location: Point(x: 0, y: 0), dx: -5, dy: 0))
        XCTAssertTrue(engine.isPrimaryActive)
        XCTAssertEqual(rec.take(1), [.keyUp(keyID: 0x61, modifiers: 0, button: 1), .leave])
        let p = rec.enteredPrimary.last!
        XCTAssertEqual(p.x, 2718)
        XCTAssertTrue(engine.layout.displays.contains { $0.contains(p) })
    }

    func testUnknownAndDuplicateNamesAreRefused() {
        engine.connectionOpened(5, address: "x")
        _ = rec.take(5)
        feed(5, .helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "stranger"))
        XCTAssertEqual(rec.take(5), [.unknownClient])
        XCTAssertEqual(rec.closed, [5])

        connectPhone(id: 6)
        engine.connectionOpened(7, address: "y")
        _ = rec.take(7)
        feed(7, .helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "phone"))
        XCTAssertEqual(rec.take(7), [.busy])
    }

    func testOldProtocolIsRejected() {
        engine.connectionOpened(2, address: "x")
        _ = rec.take(2)
        feed(2, .helloBack(protocolName: "Barrier", major: 1, minor: 3, name: "phone"))
        XCTAssertEqual(rec.take(2), [.incompatible(major: 1, minor: 6)])
    }

    func testKeepAliveAndTimeout() {
        connectPhone()
        now += 3.1
        engine.tick()
        XCTAssertEqual(rec.take(1), [.keepAlive])
        now += 6.5
        engine.tick()
        XCTAssertEqual(rec.closed, [1])
        XCTAssertTrue(engine.clients.isEmpty)
    }

    func testDisconnectWhileActiveReturnsToPrimary() {
        connectPhone()
        _ = engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0)
        XCTAssertFalse(engine.isPrimaryActive)
        engine.connectionClosed(1)
        XCTAssertTrue(engine.isPrimaryActive)
        XCTAssertEqual(rec.enteredPrimary.count, 1)
    }

    func testClipboardFlowsBothWays() throws {
        connectPhone()
        engine.primaryClipboardChanged(ClipboardContent(text: "from mac"))
        XCTAssertEqual(rec.take(1), [.grabClipboard(id: 0, sequence: 0)])

        // Data is sent when the cursor enters the phone.
        _ = engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0)
        let msgs = rec.take(1)
        guard case .enter = msgs.first else { return XCTFail("expected enter, got \(msgs)") }
        var asm = ClipboardAssembler()
        var data: Data?
        for case let .clipboardChunk(id, _, mark, d) in msgs.dropFirst() { data = try asm.add(id: id, mark: mark, data: d) }
        XCTAssertEqual(try ClipboardContent.unmarshal(data!).text, "from mac")

        // The phone copies something and publishes it.
        let chunks = ClipboardChunks.split(id: 0, sequence: 1, data: ClipboardContent(text: "from phone").marshal())
        engine.connection(1, didReceive: ([.grabClipboard(id: 0, sequence: 1)] + chunks).reduce(Data()) { $0 + Framing.frame($1) })
        XCTAssertEqual(rec.clipboards.last?.text, "from phone")
    }

    func testSwitchDelay() {
        var config = ScreenConfig.simple(server: "mac", clients: [("phone", .right)])
        config.options.switchDelay = 200
        engine.updateConfig(config)
        connectPhone()
        XCTAssertFalse(engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0))
        now += 0.1
        XCTAssertFalse(engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0))
        now += 0.15
        XCTAssertTrue(engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0))
        XCTAssertEqual(engine.activeScreen, "phone")
    }

    func testRelativeMoves() {
        var config = ScreenConfig.simple(server: "mac", clients: [("phone", .right)])
        config.options.relativeMouseMoves = true
        engine.updateConfig(config)
        engine.connectionOpened(1, address: "a")
        feed(1, .helloBack(protocolName: "Barrier", major: 1, minor: 6, name: "phone"),
             .info(x: 0, y: 0, width: 720, height: 1600, warpSize: 0, mouseX: 0, mouseY: 0))
        _ = rec.take(1)
        _ = engine.mouseMoved(location: Point(x: 2719, y: 500), dx: 3, dy: 0)
        _ = rec.take(1)
        _ = engine.mouseMoved(location: .init(x: 0, y: 0), dx: 2.6, dy: -1.2)
        XCTAssertEqual(rec.take(1), [.mouseRelMove(dx: 2, dy: -1)])
    }
}
