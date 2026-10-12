import AppKit
import Foundation
import OneCursorCore
import OneCursorMac

let usage = """
One Cursor - share one mouse and keyboard between macOS, Android and Barrier computers.

USAGE
  onecursor server [options]          share this Mac's mouse and keyboard
      --name NAME                     this screen's name (default: computer name)
      --config FILE                   Barrier-style .conf or One Cursor .json layout
      --left/--right/--up/--down NAME quick layout: put screen NAME on that side
      --port N                        listening port (default 24800)
      --no-tls                        disable encryption (Barrier's --disable-crypto)

  onecursor client HOST[:PORT] [options]   be controlled by another server
      --name NAME                     this screen's name (default: computer name)
      --no-tls                        connect without encryption
      --trust FINGERPRINT             trust this server certificate (SHA-256)

  onecursor fingerprint               show this Mac's server certificate fingerprint
  onecursor permissions               check / request the macOS permissions
  onecursor example-config            print an example Barrier-style configuration

Control+Option+Command+Esc returns the cursor to the server.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func defaultName() -> String {
    (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        .replacingOccurrences(of: " ", with: "-")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

var signalSources: [DispatchSourceSignal] = []

/// Restores the cursor and exits cleanly on Ctrl+C.
func installSignalHandlers(_ cleanup: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            cleanup()
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
}
Log.verbose = flag("--verbose")

switch command {
case "server":
    let name = option("--name") ?? defaultName()
    let port = UInt16(option("--port") ?? "24800") ?? 24800
    let useTLS = !flag("--no-tls") && !flag("--disable-crypto")
    var layout: ScreenConfig
    if let path = option("--config") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
        do {
            if path.hasSuffix(".json") {
                layout = try JSONDecoder().decode(ScreenConfig.self, from: Data(text.utf8))
            } else {
                layout = try ScreenConfig.parseBarrier(text)
            }
        } catch {
            fail("\(path): \(error)")
        }
    } else {
        var clients: [(String, Direction)] = []
        for (opt, dir) in [("--left", Direction.left), ("--right", .right), ("--up", .top), ("--down", .bottom)] {
            while let client = option(opt) { clients.append((client, dir)) }
        }
        if clients.isEmpty { fail("give a layout with --config FILE or e.g. --right my-phone") }
        layout = ScreenConfig.simple(server: name, clients: clients)
    }
    guard layout.screen(named: name) != nil else { fail("screen \"\(name)\" is not in the layout") }
    let server = MacServer(settings: .init(screenName: name, port: port, useTLS: useTLS, layout: layout))
    do {
        try server.start()
    } catch {
        fail("\(error)")
    }
    installSignalHandlers { server.stop() }
    RunLoop.main.run()

case "client":
    guard let target = args.first, !target.hasPrefix("-") else { fail("missing server address") }
    args.removeFirst()
    let name = option("--name") ?? defaultName()
    let useTLS = !flag("--no-tls") && !flag("--disable-crypto")
    var host = target
    var port: UInt16 = 24800
    if target.filter({ $0 == ":" }).count == 1, let colon = target.firstIndex(of: ":") {
        host = String(target[..<colon])
        port = UInt16(target[target.index(after: colon)...]) ?? 24800
    }
    if let fp = option("--trust") { TrustStore.shared.trust(host: host, sha256: fp) }
    let client = MacClient(settings: .init(host: host, port: port, screenName: name, useTLS: useTLS))
    client.trust = { fp in TrustStore.shared.isTrusted(host: host, sha256: fp) }
    client.onStatus = { status in
        if case .waiting = status, let fp = client.rejectedFingerprint {
            print("""
            The server's certificate is not trusted yet. Check that this fingerprint matches the one
            shown by the server, then run again with:
              --trust \(fp)
            """)
            exit(2)
        }
    }
    client.start()
    installSignalHandlers { client.stop() }
    RunLoop.main.run()

case "fingerprint":
    do {
        let id = try TLSIdentity.loadOrCreate()
        print("SHA-256: \(id.sha256)")
        print("SHA-1:   \(id.sha1)")
    } catch {
        fail("\(error)")
    }

case "permissions":
    print("Accessibility:    \(Permissions.accessibilityGranted ? "granted" : "missing")")
    print("Input Monitoring: \(Permissions.inputMonitoringGranted ? "granted" : "missing")")
    if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
    if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }

case "example-config":
    print(ScreenConfig.simple(server: defaultName(), clients: [("my-phone", .right), ("windows-pc", .left)]).barrierText())

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
