import AppKit
import CoreGraphics
import Foundation
import OneCursorCore

/// Runs One Cursor as a server on this Mac: captures the local mouse and
/// keyboard, and hands them to the active client when the cursor leaves the
/// screen. Main thread only.
public final class MacServer: ServerEngineDelegate {
    public struct Settings {
        public var screenName: String
        public var port: UInt16 = UInt16(Message.defaultPort)
        public var useTLS = true
        public var layout: ScreenConfig

        public init(screenName: String, port: UInt16 = UInt16(Message.defaultPort), useTLS: Bool = true, layout: ScreenConfig) {
            self.screenName = screenName
            self.port = port
            self.useTLS = useTLS
            self.layout = layout
        }
    }

    public private(set) var settings: Settings
    public private(set) var tlsIdentity: TLSIdentity?
    public var onStateChange: (() -> Void)?

    private let engine: ServerEngine
    private let network = NetworkServer()
    private var tap: EventTap?
    private let keys = KeyMapping()
    private let pasteboard = PasteboardWatcher()
    private var timer: Timer?
    private var parkPoint = Point(x: 0, y: 0)
    private var wheelRemainder = (x: 0.0, y: 0.0)
    private(set) public var isRunning = false

    public init(settings: Settings) {
        self.settings = settings
        engine = ServerEngine(primaryName: settings.screenName, config: settings.layout, layout: MacDisplays.layout())
        engine.delegate = self
    }

    public var activeScreen: String { engine.activeScreen }
    public var clients: [ServerEngine.ClientStatus] { engine.clients }

    public func start() throws {
        guard !isRunning else { return }
        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()
            throw EventTapError.cannotCreate
        }
        if settings.useTLS {
            let identity = try TLSIdentity.loadOrCreate()
            tlsIdentity = identity
            Log.info("TLS certificate fingerprint (SHA-256): \(identity.sha256)")
        }
        network.onOpen = { [weak self] id, address in self?.engine.connectionOpened(id, address: address) }
        network.onData = { [weak self] id, data in self?.engine.connection(id, didReceive: data) }
        network.onClose = { [weak self] id in self?.engine.connectionClosed(id) }
        network.onError = { msg in Log.info(msg) }
        try network.start(port: settings.port, tls: tlsIdentity, serviceName: settings.screenName)

        let tap = EventTap { [weak self] type, event in self?.handle(type, event) ?? false }
        do {
            try tap.start()
        } catch {
            network.stop()
            throw error
        }
        self.tap = tap
        CursorControl.disableWarpSuppression()

        pasteboard.onChange = { [weak self] content in self?.engine.primaryClipboardChanged(content) }
        pasteboard.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        isRunning = true
        Log.info("server \"\(settings.screenName)\" listening on port \(settings.port)\(settings.useTLS ? " (TLS)" : "")")
        onStateChange?()
    }

    public func stop() {
        guard isRunning else { return }
        engine.shutdown()
        tap?.stop()
        tap = nil
        network.stop()
        pasteboard.stop()
        timer?.invalidate()
        timer = nil
        CursorControl.associate(true)
        CursorControl.show()
        isRunning = false
        Log.info("server stopped")
        onStateChange?()
    }

    public func updateLayout(_ layout: ScreenConfig) {
        settings.layout = layout
        engine.updateConfig(layout)
    }

    public func returnToPrimary() { engine.returnToPrimary() }

    private func tick() {
        engine.tick()
        if engine.isPrimaryActive {
            let layout = MacDisplays.layout()
            if layout != engine.layout { engine.layout = layout }
        }
    }

    // MARK: - Event tap

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let loc = event.location
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if !engine.isPrimaryActive {
                // Keep the hidden cursor parked so it never reaches a screen edge or hot corner.
                if abs(loc.x - parkPoint.x) > 50 || abs(loc.y - parkPoint.y) > 50 { CursorControl.warp(to: parkPoint) }
            }
            return engine.mouseMoved(location: Point(x: Double(loc.x), y: Double(loc.y)), dx: dx, dy: dy)

        case .leftMouseDown: return engine.mouseButton(MouseButton.left, down: true)
        case .leftMouseUp: return engine.mouseButton(MouseButton.left, down: false)
        case .rightMouseDown: return engine.mouseButton(MouseButton.right, down: true)
        case .rightMouseUp: return engine.mouseButton(MouseButton.right, down: false)
        case .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let button: Int
            switch number {
            case 2: button = MouseButton.middle
            case 3: button = MouseButton.extra0
            case 4: button = MouseButton.extra1
            default: return !engine.isPrimaryActive
            }
            return engine.mouseButton(button, down: type == .otherMouseDown)

        case .scrollWheel:
            guard !engine.isPrimaryActive else { return false }
            // Fixed point line deltas, also fractional for trackpads. +120 per line, like Barrier.
            let vy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 120 + wheelRemainder.y
            let vx = -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 120 + wheelRemainder.x
            let iy = Int(vy), ix = Int(vx)
            wheelRemainder = (vx - Double(ix), vy - Double(iy))
            return engine.mouseWheel(dx: ix, dy: iy)

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if type == .keyDown, isReturnHotkey(code, flags) {
                engine.returnToPrimary()
                return true
            }
            let id = keys.keyID(keyCode: code, flags: flags)
            if id == KeyID.none { return !engine.isPrimaryActive }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let action: ServerEngine.KeyAction = type == .keyUp ? .up : (isRepeat ? .repeat : .down)
            return engine.key(action, keyID: id, modifiers: KeyMapping.modifiers(flags), button: Int(code) + 1)

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let flag = KeyMapping.flag(forModifierKeyCode: code), let id = KeyMapping.special[code] else {
                return !engine.isPrimaryActive
            }
            let mods = KeyMapping.modifiers(event.flags)
            if flag == .maskAlphaShift {
                // Caps Lock reports a toggle; send a full press so the client toggles too.
                _ = engine.key(.down, keyID: id, modifiers: mods, button: Int(code) + 1)
                return engine.key(.up, keyID: id, modifiers: mods, button: Int(code) + 1)
            }
            let down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
            return engine.key(down ? .down : .up, keyID: id, modifiers: mods, button: Int(code) + 1)

        case EventTap.systemDefined:
            guard !engine.isPrimaryActive, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return false
            }
            let keyCode = (ns.data1 & 0xFFFF_0000) >> 16
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            let id: Int
            switch keyCode {
            case 0: id = KeyID.audioUp      // NX_KEYTYPE_SOUND_UP
            case 1: id = KeyID.audioDown    // NX_KEYTYPE_SOUND_DOWN
            case 2: id = KeyID.brightnessUp
            case 3: id = KeyID.brightnessDown
            case 7: id = KeyID.audioMute
            case 16: id = KeyID.audioPlay
            case 17, 19: id = KeyID.audioNext
            case 18, 20: id = KeyID.audioPrev
            default: return true
            }
            return engine.key(down ? .down : .up, keyID: id, modifiers: 0, button: 0x200 + keyCode)

        default:
            return false
        }
    }

    /// Control+Option+Command+Esc always brings the cursor home.
    private func isReturnHotkey(_ code: UInt16, _ flags: CGEventFlags) -> Bool {
        code == 0x35 && flags.contains([.maskControl, .maskAlternate, .maskCommand]) && !engine.isPrimaryActive
    }

    // MARK: - ServerEngineDelegate

    public func engine(_ engine: ServerEngine, send data: Data, to connection: ConnectionID) {
        network.send(data, to: connection)
    }

    public func engine(_ engine: ServerEngine, close connection: ConnectionID) {
        network.close(connection)
    }

    public func engineDidLeavePrimary(_ engine: ServerEngine) {
        parkPoint = MacDisplays.mainBounds().center
        CursorControl.warp(to: parkPoint)
        CursorControl.associate(false)
        CursorControl.hide()
    }

    public func engine(_ engine: ServerEngine, didEnterPrimaryAt point: Point) {
        CursorControl.associate(true)
        CursorControl.warp(to: point)
        CursorControl.show()
    }

    public func engine(_ engine: ServerEngine, setPrimaryClipboard content: ClipboardContent) {
        pasteboard.set(content)
    }

    public func engineStateDidChange(_ engine: ServerEngine) {
        onStateChange?()
    }

    public func engine(_ engine: ServerEngine, log message: String) {
        Log.info(message)
    }
}
