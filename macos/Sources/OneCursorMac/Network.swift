import CryptoKit
import Foundation
import Network
import OneCursorCore
import Security

private func tcpParameters(tls: NWProtocolTLS.Options?) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    let params = NWParameters(tls: tls, tcp: tcp)
    params.allowLocalEndpointReuse = true
    return params
}

/// TCP (optionally TLS) listener that hands raw bytes to the server engine
/// and advertises itself over Bonjour as `_onecursor._tcp`. Main queue only.
public final class NetworkServer {
    public var onOpen: ((ConnectionID, String) -> Void)?
    public var onData: ((ConnectionID, Data) -> Void)?
    public var onClose: ((ConnectionID) -> Void)?
    public var onError: ((String) -> Void)?

    private var listener: NWListener?
    private var connections: [ConnectionID: NWConnection] = [:]
    private var nextID = 1

    public init() {}

    public static let serviceType = "_onecursor._tcp"

    public func start(port: UInt16, tls: TLSIdentity?, serviceName: String) throws {
        var tlsOptions: NWProtocolTLS.Options?
        if let tls {
            let opts = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(tls.identity) else {
                throw TLSIdentityError.generationFailed("sec_identity_create failed")
            }
            sec_protocol_options_set_local_identity(opts.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(opts.securityProtocolOptions, .TLSv12)
            tlsOptions = opts
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let l = try NWListener(using: tcpParameters(tls: tlsOptions), on: nwPort)
        l.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil,
                                       txtRecord: Self.txtRecord(["tls": tls == nil ? "0" : "1", "proto": "barrier-1.6"]))
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.onError?("listener failed: \(err)")
            }
        }
        l.start(queue: .main)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
    }

    public func send(_ data: Data, to id: ConnectionID) {
        connections[id]?.send(content: data, completion: .contentProcessed { _ in })
    }

    public func close(_ id: ConnectionID) {
        guard let c = connections.removeValue(forKey: id) else { return }
        // Let queued data (e.g. an error message) go out before closing.
        c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        onClose?(id)
    }

    private func accept(_ c: NWConnection) {
        let id = nextID
        nextID += 1
        connections[id] = c
        let address: String
        switch c.endpoint {
        case let .hostPort(host, _): address = "\(host)"
        default: address = "\(c.endpoint)"
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onOpen?(id, address)
                self.receive(c, id)
            case .failed(let err):
                Log.info("connection from \(address) failed: \(err)")
                self.dropped(id)
            case .cancelled:
                self.dropped(id)
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    private func receive(_ c: NWConnection, _ id: ConnectionID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if let data, !data.isEmpty { self.onData?(id, data) }
            if complete || error != nil {
                self.dropped(id)
                c.cancel()
            } else {
                self.receive(c, id)
            }
        }
    }

    private func dropped(_ id: ConnectionID) {
        guard connections.removeValue(forKey: id) != nil else { return }
        onClose?(id)
    }

    static func txtRecord(_ entries: [String: String]) -> Data {
        var d = Data()
        for (k, v) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(k)=\(v)".utf8)
            d.append(UInt8(entry.count))
            d.append(entry)
        }
        return d
    }
}

/// Outgoing connection for client mode. Main queue only.
public final class NetworkClient {
    public var onReady: (() -> Void)?
    public var onData: ((Data) -> Void)?
    public var onClose: ((String?) -> Void)?

    private var connection: NWConnection?
    private var closed = false

    public init() {}

    /// `trust` decides whether a TLS server certificate (by SHA-256 fingerprint) is accepted.
    public func connect(host: String, port: UInt16, tls: Bool, trust: @escaping (_ sha256: String) -> Bool) {
        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let opts = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(opts.securityProtocolOptions, { _, secTrust, complete in
                let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate], let leaf = chain.first else {
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let fp = TLSIdentity.hex(Data(SHA256.hash(data: der)))
                complete(trust(fp))
            }, .main)
            tlsOptions = opts
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 24800,
                             using: tcpParameters(tls: tlsOptions))
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive(c)
            case .failed(let err):
                self.finish("\(err)")
            case .waiting(let err):
                self.finish("\(err)")
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    public func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    public func close() {
        connection?.cancel()
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if complete {
                self.finish("server closed the connection")
            } else if let error {
                self.finish("\(error)")
            } else {
                self.receive(c)
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        onClose?(reason)
    }
}
