import AppKit
import Combine
import OneCursorCore
import OneCursorMac
import SwiftUI

/// A screen placed next to this Mac in the simple layout editor.
struct Placement: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var side: Direction
}

enum Mode: String, Codable, CaseIterable, Identifiable {
    case server, client
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    // Persisted settings
    @Published var mode: Mode { didSet { save() } }
    @Published var screenName: String { didSet { save() } }
    @Published var port: Int { didSet { save() } }
    @Published var useTLS: Bool { didSet { save() } }
    @Published var placements: [Placement] { didSet { save(); layoutChanged() } }
    @Published var switchDelay: Int { didSet { save(); layoutChanged() } }
    @Published var clipboardSharing: Bool { didSet { save(); layoutChanged() } }
    /// A configuration imported from a Barrier .conf file; replaces `placements` when set.
    @Published var customConfig: ScreenConfig? { didSet { save(); layoutChanged() } }
    @Published var serverHost: String { didSet { save() } }
    @Published var startAtLaunch: Bool { didSet { save() } }

    // Runtime state
    @Published private(set) var running = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var clients: [ServerEngine.ClientStatus] = []
    @Published private(set) var activeScreen = ""
    @Published private(set) var fingerprint: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var inputMonitoringGranted = Permissions.inputMonitoringGranted
    @Published var pendingFingerprint: String?

    private var server: MacServer?
    private var client: MacClient?
    private var permissionTimer: Timer?
    private let defaults = UserDefaults.standard
    private var loading = true

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .server
        screenName = d.string(forKey: "screenName") ?? AppModel.defaultName()
        port = d.object(forKey: "port") as? Int ?? Message.defaultPort
        useTLS = d.object(forKey: "useTLS") as? Bool ?? true
        placements = (d.data(forKey: "placements")).flatMap { try? JSONDecoder().decode([Placement].self, from: $0) }
            ?? [Placement(name: "android", side: .right)]
        switchDelay = d.integer(forKey: "switchDelay")
        clipboardSharing = d.object(forKey: "clipboardSharing") as? Bool ?? true
        customConfig = d.data(forKey: "customConfig").flatMap { try? JSONDecoder().decode(ScreenConfig.self, from: $0) }
        serverHost = d.string(forKey: "serverHost") ?? ""
        startAtLaunch = d.bool(forKey: "startAtLaunch")
        loading = false

        Log.sink = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        if let id = try? TLSIdentity.loadOrCreate() { fingerprint = id.sha256 }
        if startAtLaunch { start() }
    }

    static func defaultName() -> String {
        (Host.current().localizedName ?? "mac").replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - Layout

    var layout: ScreenConfig {
        var config = customConfig ?? ScreenConfig.simple(server: screenName, clients: placements
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.name.trimmingCharacters(in: .whitespaces), $0.side) })
        config.options.switchDelay = switchDelay
        config.options.clipboardSharing = clipboardSharing
        return config
    }

    func importBarrierConfig(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let config = try ScreenConfig.parseBarrier(text)
        customConfig = config
        if config.screen(named: screenName) == nil, let first = config.screens.first {
            screenName = first.name
        }
    }

    func exportBarrierConfig(to url: URL) throws {
        try layout.barrierText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func layoutChanged() {
        guard !loading else { return }
        server?.updateLayout(layout)
    }

    // MARK: - Start / stop

    func start() {
        stop()
        switch mode {
        case .server:
            let config = layout
            guard config.screen(named: screenName) != nil else {
                statusText = "“\(screenName)” is not in the layout"
                return
            }
            let s = MacServer(settings: .init(screenName: screenName, port: UInt16(clamping: port), useTLS: useTLS, layout: config))
            s.onStateChange = { [weak self] in
                Task { @MainActor in self?.serverStateChanged() }
            }
            do {
                try s.start()
                server = s
                fingerprint = s.tlsIdentity?.sha256 ?? fingerprint
                running = true
                serverStateChanged()
            } catch {
                statusText = "\(error)"
                append(statusText)
            }
        case .client:
            let host = serverHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                statusText = "Enter the server address"
                return
            }
            var h = host
            var p = UInt16(clamping: port)
            if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
                h = String(host[..<colon])
                p = UInt16(host[host.index(after: colon)...]) ?? p
            }
            let c = MacClient(settings: .init(host: h, port: p, screenName: screenName, useTLS: useTLS))
            c.trust = { fp in TrustStore.shared.isTrusted(host: h, sha256: fp) }
            c.onStatus = { [weak self, weak c] status in
                Task { @MainActor in self?.clientStatusChanged(status, rejected: c?.rejectedFingerprint) }
            }
            client = c
            running = true
            c.start()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        client?.stop()
        client = nil
        running = false
        clients = []
        activeScreen = ""
        statusText = "Stopped"
    }

    func returnCursor() { server?.returnToPrimary() }

    func trustPendingFingerprint() {
        guard let fp = pendingFingerprint, let c = client else { return }
        TrustStore.shared.trust(host: c.settings.host, sha256: fp)
        pendingFingerprint = nil
        c.reconnect()
    }

    private func serverStateChanged() {
        guard let s = server else { return }
        clients = s.clients
        activeScreen = s.activeScreen
        statusText = clients.isEmpty ? "Waiting for screens to connect" : "Sharing with \(clients.map(\.name).joined(separator: ", "))"
    }

    private func clientStatusChanged(_ status: MacClient.Status, rejected: String?) {
        switch status {
        case .stopped: statusText = "Stopped"
        case .connecting: statusText = "Connecting…"
        case .connected(let proto): statusText = "Connected (\(proto))"
        case .waiting(let why):
            statusText = "Disconnected: \(why)"
            if let rejected { pendingFingerprint = rejected }
        }
    }

    // MARK: - Misc

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func save() {
        guard !loading else { return }
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(screenName, forKey: "screenName")
        defaults.set(port, forKey: "port")
        defaults.set(useTLS, forKey: "useTLS")
        defaults.set(try? JSONEncoder().encode(placements), forKey: "placements")
        defaults.set(switchDelay, forKey: "switchDelay")
        defaults.set(clipboardSharing, forKey: "clipboardSharing")
        defaults.set(customConfig.flatMap { try? JSONEncoder().encode($0) }, forKey: "customConfig")
        defaults.set(serverHost, forKey: "serverHost")
        defaults.set(startAtLaunch, forKey: "startAtLaunch")
    }
}
