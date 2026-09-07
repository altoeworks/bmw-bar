import CocoaMQTT
import Foundation
import Network

/// A CocoaMQTT transport built on Network.framework.
///
/// **Why this exists:** BMW's broker is TLS 1.3-only — a TLS 1.2 ClientHello is
/// answered with alert 70 (`protocol_version`), surfacing as SecureTransport error
/// -9836. CocoaMQTT's stock socket uses CocoaAsyncSocket's `startTLS`, which goes
/// through SecureTransport, and Apple never added TLS 1.3 to that API. No combination
/// of `sslSettings` can fix it; the transport itself has to change.
///
/// `NWConnection` negotiates TLS 1.3 and, conveniently, its
/// `receive(minimumIncompleteLength:maximumLength:)` delivers exactly-sized reads,
/// which is precisely what `readData(toLength:)` needs — so no buffering layer.
public final class NetworkFrameworkSocket: CocoaMQTTSocketProtocol, @unchecked Sendable {
    public var enableSSL = true
    /// Lowest version we will negotiate. BMW needs 1.3; 1.2 is allowed so this class
    /// stays usable against an ordinary broker.
    public var minimumTLSVersion: tls_protocol_version_t = .TLSv12

    private weak var delegate: CocoaMQTTSocketDelegate?
    private var delegateQueue: DispatchQueue = .main
    private let queue = DispatchQueue(label: "com.ohoefenstock.bmw-bar.nwsocket")
    private var connection: NWConnection?
    /// Guards against reporting a disconnect more than once, or after `disconnect()`.
    private var hasReportedDisconnect = false

    public init() {}

    public func setDelegate(_ theDelegate: CocoaMQTTSocketDelegate?, delegateQueue: DispatchQueue?) {
        self.delegate = theDelegate
        if let delegateQueue { self.delegateQueue = delegateQueue }
    }

    public func connect(toHost host: String, onPort port: UInt16) throws {
        try connect(toHost: host, onPort: port, withTimeout: -1)
    }

    public func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        let parameters: NWParameters = enableSSL
            ? NWParameters(tls: tlsOptions(serverName: host), tcp: .init())
            : NWParameters(tls: nil, tcp: .init())

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8883,
            using: parameters
        )
        self.connection = connection
        hasReportedDisconnect = false

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.delegateQueue.async { self.delegate?.socketConnected(self) }
            case .failed(let error):
                self.reportDisconnect(error)
            case .cancelled:
                self.reportDisconnect(nil)
            case .waiting(let error):
                // `waiting` means the path is unusable (DNS, refused, TLS alert).
                // MQTT sessions are short-lived here, so surface it instead of
                // silently waiting for the network to improve.
                self.reportDisconnect(error)
            default:
                break
            }
        }

        connection.start(queue: queue)

        if timeout > 0 {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let connection = self.connection,
                      connection.state != .ready else { return }
                self.reportDisconnect(NWError.posix(.ETIMEDOUT))
            }
        }
    }

    public func disconnect() {
        // A deliberate teardown; suppress the resulting `.cancelled` callback so the
        // client doesn't see it as a connection failure.
        hasReportedDisconnect = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    public func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        guard let connection else { return }
        let wanted = Int(length)

        connection.receive(minimumIncompleteLength: wanted, maximumLength: wanted) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.reportDisconnect(error)
                return
            }
            if let content, content.count == wanted {
                self.delegateQueue.async { self.delegate?.socket(self, didRead: content, withTag: tag) }
                return
            }
            // Short read or EOF: the peer closed mid-frame, so the session is over.
            if isComplete || content == nil {
                self.reportDisconnect(nil)
            }
        }
    }

    public func write(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        guard let connection else { return }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.reportDisconnect(error)
                return
            }
            self.delegateQueue.async { self.delegate?.socket(self, didWriteDataWithTag: tag) }
        })
    }

    // MARK: - Helpers

    private func tlsOptions(serverName: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            minimumTLSVersion
        )
        // SNI: BMW terminates TLS behind a shared front end, so the server name has
        // to be sent for the right certificate to come back.
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverName)
        return options
    }

    private func reportDisconnect(_ error: Error?) {
        queue.async { [weak self] in
            guard let self, !self.hasReportedDisconnect else { return }
            self.hasReportedDisconnect = true
            self.delegateQueue.async { self.delegate?.socketDidDisconnect(self, withError: error) }
        }
    }
}
