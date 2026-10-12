import CryptoKit
import Foundation
import Security

public enum TLSIdentityError: Error, CustomStringConvertible {
    case generationFailed(String)
    case importFailed(OSStatus)

    public var description: String {
        switch self {
        case .generationFailed(let s): return "could not create a TLS certificate: \(s)"
        case .importFailed(let s): return "could not load the TLS certificate (OSStatus \(s))"
        }
    }
}

/// The server's self-signed TLS identity, created on first use. Clients pin
/// its fingerprint, as Barrier does.
public struct TLSIdentity {
    public let identity: SecIdentity
    /// Colon separated upper-case hex, the format Barrier shows.
    public let sha256: String
    public let sha1: String

    static let passphrase = "onecursor"

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OneCursor/TLS", isDirectory: true)
    }

    public static func loadOrCreate(in dir: URL = defaultDirectory) throws -> TLSIdentity {
        let p12 = dir.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try generate(in: dir)
        }
        let data = try Data(contentsOf: p12)
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        if #available(macOS 15.0, *) {
            // Keep the key out of the login keychain.
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]],
              let first = list.first, let ref = first[kSecImportItemIdentity as String] else {
            throw TLSIdentityError.importFailed(status)
        }
        let identity = ref as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        let der = cert.map { SecCertificateCopyData($0) as Data } ?? Data()
        return TLSIdentity(identity: identity, sha256: hex(Data(SHA256.hash(data: der))), sha1: hex(Data(Insecure.SHA1.hash(data: der))))
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: ":") }

    /// Uses the system's LibreSSL, like Barrier does with OpenSSL.
    private static func generate(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        let p12 = dir.appendingPathComponent("identity.p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "3650",
                 "-subj", "/CN=OneCursor", "-keyout", key, "-out", cert])
        try run(["pkcs12", "-export", "-in", cert, "-inkey", key, "-out", p12, "-name", "OneCursor",
                 "-passout", "pass:\(passphrase)"])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12)
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TLSIdentityError.generationFailed(msg)
        }
    }
}
