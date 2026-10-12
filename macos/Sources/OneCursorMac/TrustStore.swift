import Foundation

/// Pinned server certificate fingerprints for client mode, one "host fingerprint" per line.
public final class TrustStore {
    public static let shared = TrustStore()

    private let url: URL
    private var entries: [String: String] = [:]

    public init(url: URL = TLSIdentity.defaultDirectory.deletingLastPathComponent().appendingPathComponent("trusted-servers.txt")) {
        self.url = url
        load()
    }

    public func isTrusted(host: String, sha256: String) -> Bool {
        entries[host.lowercased()].map { normalize($0) == normalize(sha256) } ?? false
    }

    public func trust(host: String, sha256: String) {
        entries[host.lowercased()] = sha256
        save()
    }

    private func normalize(_ s: String) -> String { s.filter { $0.isHexDigit }.uppercased() }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { entries[parts[0]] = parts[1] }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = entries.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
