import AppKit
import CoreGraphics
import Foundation
import OneCursorCore

/// Runs this Mac as a client of a One Cursor / Barrier / Input Leap server.
/// Reconnects automatically. Main thread only.
public final class MacClient: ClientEngineDelegate {
    public struct Settings {
        public var host: String
        public var port: UInt16
        public var screenName: String
        public var useTLS: Bool

        public init(host: String, port: UInt16 = UInt16(Message.defaultPort), screenName: String, useTLS: Bool = true) {
            self.host = host
            self.port = port
            self.screenName = screenName
            self.useTLS = useTLS
        }
    }

    public enum Status: Equatable {
        case stopped
        case connecting
        case connected(String)
        case waiting(String)
    }

    public let settings: Settings
    /// Decides whether to trust a server certificate fingerprint (SHA-256).
    public var trust: (String) -> Bool = { _ in false }
    public var onStatus: ((Status) -> Void)?
    public private(set) var status: Status = .stopped {
        didSet { onStatus?(status) }
    }
    /// The fingerprint of the last certificate that was rejected, so the UI can offer to trust it.
    public private(set) var rejectedFingerprint: String?

    private var network: NetworkClient?
    private var engine: ClientEngine?
    private let injector = EventInjector()
    private let pasteboard = PasteboardWatcher()
    private var timer: Timer?
    private var retryWork: DispatchWorkItem?
    private var running = false
    private var retryDelay: TimeInterval = 1
    private var screenObserver: NSObjectProtocol?

    public init(settings: Settings) {
        self.settings = settings
    }

    public func start() {
        guard !running else { return }
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        running = true
        pasteboard.onChange = { [weak self] content in self?.engine?.sendClipboard(content) }
        pasteboard.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.engine?.tick() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engine?.screenChanged() }
        connect()
    }

    public func stop() {
        running = false
        retryWork?.cancel()
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pasteboard.stop()
        network?.close()
        network = nil
        engine = nil
        injector.releaseAll()
        status = .stopped
    }

    private func connect() {
        guard running else { return }
        status = .connecting
        rejectedFingerprint = nil
        let engine = ClientEngine(name: settings.screenName)
        engine.delegate = self
        self.engine = engine
        let net = NetworkClient()
        network = net
        net.onReady = { [weak self] in
            self?.engine?.connected()
            Log.info("connected to \(self?.settings.host ?? "")")
        }
        net.onData = { [weak self] data in self?.engine?.receive(data) }
        net.onClose = { [weak self] reason in self?.connectionEnded(reason) }
        net.connect(host: settings.host, port: settings.port, tls: settings.useTLS) { [weak self] fp in
            guard let self else { return false }
            if self.trust(fp) { return true }
            self.rejectedFingerprint = fp
            Log.info("server certificate not trusted: \(fp)")
            return false
        }
    }

    private func connectionEnded(_ reason: String?) {
        injector.releaseAll()
        network = nil
        engine = nil
        guard running else { return }
        let why = rejectedFingerprint != nil ? "untrusted certificate" : (reason ?? "disconnected")
        Log.info("connection ended: \(why)")
        status = .waiting(why)
        if rejectedFingerprint != nil { return } // wait for the user to trust it
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 15)
    }

    /// Retry now (e.g. after the user trusted the certificate).
    public func reconnect() {
        retryWork?.cancel()
        network?.close()
        if network == nil { connect() }
    }

    // MARK: - ClientEngineDelegate

    public func clientEngine(_ engine: ClientEngine, send data: Data) { network?.send(data) }

    public func clientEngine(_ engine: ClientEngine, disconnectWithReason reason: String) {
        Log.info(reason)
        network?.close()
    }

    public func clientEngineDidConnect(_ engine: ClientEngine, serverProtocol: String) {
        retryDelay = 1
        status = .connected(serverProtocol)
    }

    public func clientEngineScreenShape(_ engine: ClientEngine) -> Rect { MacDisplays.layout().bounds }

    public func clientEngineCursorPosition(_ engine: ClientEngine) -> Point {
        let p = CGEvent(source: nil)?.location ?? .zero
        return Point(x: Double(p.x), y: Double(p.y))
    }

    public func clientEngine(_ engine: ClientEngine, enterAt point: Point, modifiers: Int) {
        injector.warp(to: CGPoint(x: point.x, y: point.y))
    }

    public func clientEngineLeave(_ engine: ClientEngine) {
        injector.releaseAll()
    }

    public func clientEngine(_ engine: ClientEngine, mouseMoveTo point: Point) {
        injector.move(to: CGPoint(x: point.x, y: point.y))
    }

    public func clientEngine(_ engine: ClientEngine, mouseMoveBy dx: Int, _ dy: Int) {
        let bounds = MacDisplays.layout()
        let p = bounds.nearestPoint(to: Point(x: Double(injector.position.x) + Double(dx), y: Double(injector.position.y) + Double(dy)))
        injector.move(to: CGPoint(x: p.x, y: p.y))
    }

    public func clientEngine(_ engine: ClientEngine, mouseButton button: Int, down: Bool) {
        injector.button(button, down: down)
    }

    public func clientEngine(_ engine: ClientEngine, wheel dx: Int, _ dy: Int) {
        injector.wheel(dx: dx, dy: dy)
    }

    public func clientEngine(_ engine: ClientEngine, key keyID: Int, modifiers: Int, button: Int,
                             action: ServerEngine.KeyAction, count: Int) {
        injector.key(keyID, modifiers: modifiers, button: button, action: action, count: count)
    }

    public func clientEngine(_ engine: ClientEngine, clipboard content: ClipboardContent) {
        pasteboard.set(content)
    }
}
