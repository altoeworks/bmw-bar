import CocoaMQTT
import Foundation

/// Live vehicle data over BMW's MQTT broker.
///
/// This is the primary data source: it is not metered, whereas REST is capped at 50
/// calls a day. Three BMW-specific constraints shape the implementation:
///
/// 1. The MQTT password is the `id_token`, which expires after an hour, so the
///    connection is torn down and rebuilt with a fresh token before that happens.
/// 2. BMW disconnects clients idle for 60 s, so keep-alive is 25 s.
/// 3. **One connection per account.** A second consumer (Home Assistant, evcc, another
///    copy of this app) makes BMW reject this one even though the token is perfectly
///    valid. Observed directly: the broker answers `0x97 quotaExceeded`, not the
///    `notAuthorized` this once assumed. Reported as its own state rather than retried
///    forever as if it were an auth failure.
///
/// All mutable state is confined to `queue`, which is also CocoaMQTT's delegate queue.
public final class CarDataStream: NSObject, @unchecked Sendable {
    /// How the MQTT session is opened, which decides what happens to messages published
    /// while this Mac is asleep or off the network.
    ///
    /// `clean` throws them away: the broker forgets the subscription the moment the
    /// socket drops. `persistent` asks the broker to keep the subscription and queue
    /// QoS 1 messages until we come back — the difference between waking up to the car's
    /// real state and waking up to yesterday's.
    ///
    /// BMW documents neither, so which one is used is decided by trying (see
    /// `onPersistentSessionVerdict`).
    public enum SessionMode: Equatable, Sendable {
        case clean
        case persistent(clientID: String, expiry: UInt32)

        public var isPersistent: Bool {
            if case .persistent = self { return true }
            return false
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        case connected
        /// BMW refused the credentials. `heldElsewhere` when the token is known-good,
        /// which almost always means another client holds the single allowed session.
        case refused(heldElsewhere: Bool, reason: String)
        case disconnected(String?)

        public var isConnected: Bool { self == .connected }

        public var summary: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Live"
            case .refused(let heldElsewhere, let reason):
                return heldElsewhere
                    ? "Stream already in use by another client"
                    : "BMW refused the stream (\(reason))"
            case .disconnected(let reason):
                return reason.map { "Disconnected: \($0)" } ?? "Disconnected"
            }
        }
    }

    public static let host = "customer.streaming-cardata.bmwgroup.com"
    public static let port: UInt16 = 9000
    /// BMW drops idle clients at 60 s; stay well inside that.
    static let keepAlive: UInt16 = 25
    /// Rebuild the connection this long before the id_token expires.
    static let reconnectMargin: TimeInterval = 5 * 60
    /// How long to wait before re-testing a stream another client is holding.
    static let retryHeldElsewhere: TimeInterval = 5 * 60
    /// How long BMW is asked to hold the session — and its queue — after we disconnect.
    /// The broker may grant less; its CONNACK value is the one that counts.
    public static let sessionExpiry: UInt32 = 24 * 60 * 60

    private let tokens: TokenStore
    /// `nil` subscribes to the wildcard topic and learns the VIN from the first
    /// message — which is what lets a fresh install start with zero REST calls.
    private let vin: String?
    private let queue = DispatchQueue(label: "com.ohoefenstock.bmw-bar.stream")
    /// What was asked for. `activeMode` is what is actually in use, which differs once
    /// a persistent attempt has been downgraded.
    private let requestedMode: SessionMode

    // Guarded by `queue`.
    private var client: CocoaMQTT5?
    private var continuation: AsyncStream<StreamMessage>.Continuation?
    private var _status: Status = .idle
    /// Set while we tear the connection down ourselves to rotate the token, so the
    /// resulting disconnect is not mistaken for a failure.
    private var isRotatingToken = false
    private var isStopping = false
    private var discoveredVIN: String?
    private var activeMode: SessionMode
    /// Set when a persistent connect was refused, so the retry opens a clean session and
    /// the refusal is not misread as "another client holds the stream".
    private var didDowngrade = false
    private var verdictReported = false

    private var lifecycleTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    /// Called on the stream's own queue whenever the connection state changes.
    public var onStatusChange: (@Sendable (Status) -> Void)?

    public var status: Status { queue.sync { _status } }

    /// Called on the stream's queue the first time a VIN is seen, so it can be
    /// persisted without ever asking BMW's REST API which vehicles exist.
    public var onVINDiscovered: (@Sendable (String) -> Void)?

    /// Whether BMW actually accepted a persistent session, reported once it is known, so
    /// the answer can be cached instead of re-discovered on every launch.
    public var onPersistentSessionVerdict: (@Sendable (Bool) -> Void)?

    /// The session mode currently in use, which may be `.clean` even when `.persistent`
    /// was asked for.
    public var sessionMode: SessionMode { queue.sync { activeMode } }

    /// - Parameters:
    ///   - vin: the vehicle to follow, or `nil` to subscribe to every vehicle on the
    ///     account and discover the VIN from the stream.
    ///   - mode: whether to ask BMW to hold the session while we are away. A refused
    ///     persistent session downgrades itself to `.clean` on the spot.
    public init(tokens: TokenStore, vin: String? = nil, mode: SessionMode = .clean) {
        self.tokens = tokens
        self.vin = vin
        self.requestedMode = mode
        self.activeMode = mode
    }

    /// Messages, in arrival order. Call `start()` to connect and `stop()` to finish.
    /// - Note: bounded on purpose. `AsyncStream`'s default policy is `.unbounded`, so a
    ///   burst the consumer can't keep up with grows without limit — BMW really does
    ///   send bursts (82 messages in one second has been observed, one per descriptor).
    ///   These are sparse deltas, so under genuine pressure discarding the oldest is far
    ///   better than unbounded growth.
    public func messages() -> AsyncStream<StreamMessage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            queue.sync { self.continuation = continuation }
        }
    }

    public func start() {
        queue.sync { isStopping = false }
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in await self?.runLifecycle() }
    }

    public func stop() {
        teardown()
        queue.sync {
            continuation?.finish()
            continuation = nil
        }
    }

    /// Disconnects without ending the message stream, so the same consumer picks back up
    /// after `resume()`.
    ///
    /// Used when the Mac is about to sleep. Disconnecting deliberately is not the same as
    /// vanishing: a clean MQTT DISCONNECT leaves a persistent session — and everything the
    /// broker queues into it — intact, where a socket left to rot gets torn down by BMW's
    /// 60 s idle timeout instead.
    public func pause() {
        Log.stream.notice("pausing (mode: \(self.sessionMode.isPersistent ? "persistent" : "clean", privacy: .public))")
        teardown()
    }

    public func resume() {
        Log.stream.notice("resuming")
        start()
    }

    /// Rebuilds the connection immediately instead of waiting out the backoff.
    ///
    /// After a wake or a network change the existing wait is worthless: `backOff()` may
    /// have up to two minutes left to run, and its `Task.sleep` drifted through the sleep
    /// anyway. Cancelling the lifecycle interrupts both.
    public func reconnectNow() {
        guard !queue.sync(execute: { isStopping }) else { return }
        Log.stream.notice("reconnecting now")
        teardown()
        start()
    }

    /// Drops the connection and the lifecycle task, leaving the message stream open.
    private func teardown() {
        queue.sync {
            isStopping = true
            client?.disconnect()
            client = nil
            setStatus(.idle)
        }
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    // MARK: - Lifecycle

    private enum Hold {
        /// The id_token is about to expire; rebuild with a fresh one.
        case rotate
        /// The connection dropped unexpectedly.
        case lost
        /// BMW refused the credentials. `heldElsewhere` means another client holds
        /// the single allowed session, which may free up later.
        case refused(heldElsewhere: Bool)
        case cancelled
    }

    /// Connects, holds the session until the `id_token` nears expiry, then rotates.
    /// Unexpected drops reconnect with exponential backoff. Runs until `stop()`.
    private func runLifecycle() async {
        while !Task.isCancelled, !queue.sync(execute: { isStopping }) {
            let tokenSet: TokenSet
            do {
                tokenSet = try await tokens.validTokens()
            } catch {
                queue.sync { setStatus(.disconnected("auth: \(String(describing: error))")) }
                guard await backOff() else { return }
                continue
            }

            connect(with: tokenSet)

            let rotateAt = tokenSet.accessExpiresAt.addingTimeInterval(-Self.reconnectMargin)
            switch await hold(until: rotateAt) {
            case .cancelled:
                return

            case .refused(let heldElsewhere):
                queue.sync {
                    client?.disconnect()
                    client = nil
                }
                // Bad credentials will never start working on their own; the user has
                // to re-authorise. But "held elsewhere" is temporary — the other
                // client may disconnect — so keep checking back, slowly.
                guard heldElsewhere else { return }
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.retryHeldElsewhere * 1_000_000_000))
                } catch {
                    return
                }

            case .lost:
                queue.sync {
                    client?.disconnect()
                    client = nil
                }
                guard await backOff() else { return }

            case .rotate:
                queue.sync {
                    isRotatingToken = true
                    client?.disconnect()
                    client = nil
                }
                // Force a refresh so the next connection gets a genuinely fresh
                // id_token rather than the one about to expire.
                _ = try? await tokens.forceRefresh()
                queue.sync { isRotatingToken = false }
                reconnectAttempt = 0
            }
        }
    }

    /// Waits for the rotation deadline, watching for a dropped connection meanwhile.
    /// Polling keeps this simple and costs nothing at a 2 s interval.
    private func hold(until deadline: Date) async -> Hold {
        while true {
            if Task.isCancelled { return .cancelled }

            let outcome: Hold? = queue.sync {
                if isStopping { return .cancelled }
                if case .refused(let heldElsewhere, _) = _status {
                    return .refused(heldElsewhere: heldElsewhere)
                }
                if case .disconnected = _status { return .lost }
                return nil
            }
            if let outcome { return outcome }
            if Date() >= deadline { return .rotate }

            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return .cancelled
            }
        }
    }

    private func connect(with tokens: TokenSet) {
        queue.sync {
            // A persistent session is keyed on the client id, so it has to be the same
            // one every time; a clean session has nothing to resume, so a throwaway id
            // avoids colliding with anything.
            let clientID: String
            let properties: MqttConnectProperties?
            switch activeMode {
            case .clean:
                clientID = "bmw-bar-\(UUID().uuidString.prefix(8))"
                properties = nil
            case .persistent(let stable, let expiry):
                clientID = stable
                let connectProperties = MqttConnectProperties()
                connectProperties.sessionExpiryInterval = expiry
                properties = connectProperties
            }

            // BMW's broker is TLS 1.3-only, which CocoaMQTT's stock SecureTransport
            // socket cannot negotiate; see NetworkFrameworkSocket.
            let client = CocoaMQTT5(
                clientID: clientID,
                host: Self.host,
                port: Self.port,
                socket: NetworkFrameworkSocket()
            )
            client.username = tokens.gcid
            client.password = tokens.idToken
            client.enableSSL = true
            client.keepAlive = Self.keepAlive
            // MQTT 5 spells this Clean Start: false asks the broker to keep our
            // subscription and queue QoS 1 messages while we are gone.
            client.cleanSession = !activeMode.isPersistent
            client.connectProperties = properties
            // Reconnects are driven by `runLifecycle` so the token can be refreshed
            // first; CocoaMQTT's own retry would keep replaying a dead credential.
            client.autoReconnect = false
            client.delegate = self
            client.delegateQueue = queue

            self.client = client
            setStatus(.connecting)
            _ = client.connect()
        }
    }

    /// Topics are `{gcid}/{vin}`, so the VIN is recoverable even from a payload that
    /// omits it.
    static func vin(fromTopic topic: String) -> String? {
        let parts = topic.split(separator: "/")
        guard parts.count >= 2, let last = parts.last, !last.isEmpty, last != "+" else {
            return nil
        }
        return String(last)
    }

    /// Must be called on `queue`.
    private func setStatus(_ new: Status) {
        guard _status != new else { return }
        _status = new
        onStatusChange?(new)
    }

    /// Exponential backoff, capped at two minutes. Returns false if cancelled.
    private func backOff() async -> Bool {
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempt, 7))), 120)
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - CocoaMQTT5Delegate
// All of these arrive on `queue`.

extension CarDataStream: CocoaMQTT5Delegate {
    public func mqtt5(
        _ mqtt5: CocoaMQTT5,
        didConnectAck ack: CocoaMQTTCONNACKReasonCode,
        connAckData: MqttDecodeConnAck?
    ) {
        switch ack {
        case .success:
            reconnectAttempt = 0
            if let granted = connAckData?.sessionExpiryInterval {
                Log.stream.notice("broker session expiry: \(granted, privacy: .public)s")
            }
            reportVerdict(activeMode.isPersistent)
            setStatus(.connected)
            // `{gcid}/+` covers every vehicle on the account; `{gcid}/{vin}` narrows to
            // one. BMW documents both. Re-subscribing on a resumed session is harmless:
            // MQTT replaces the existing subscription rather than duplicating it.
            let topic = "\(mqtt5.username ?? "")/\(vin ?? "+")"
            mqtt5.subscribe(topic, qos: .qos1)

        case _ where Self.isContention(ack):
            // Contention says nothing about whether BMW supports persistent sessions, so
            // it must not trigger the downgrade below. A clean retry mints a *fresh*
            // client id, so it would very likely succeed — and we would then cache
            // "persistent sessions refused" for a week on the strength of a second copy
            // of the app being open for a minute.
            setStatus(.refused(heldElsewhere: ack != .badUsernameOrPassword, reason: "\(ack)"))

        default:
            // Nothing in MQTT 5 says "clean start refused" outright: a broker that will
            // not hold a session simply accepts the connection and reports no session
            // present. So the only honest test is behavioural — if the persistent attempt
            // failed and a clean one works, persistence is what BMW objected to.
            if activeMode.isPersistent, !didDowngrade {
                didDowngrade = true
                activeMode = .clean
                Log.stream.notice("persistent session refused (CONNACK \(String(describing: ack), privacy: .public)); retrying clean")
                setStatus(.disconnected("persistent session refused (\(ack))"))
                return
            }
            if didDowngrade { reportVerdict(false) }
            setStatus(.disconnected("CONNACK \(ack)"))
        }
    }

    /// Whether a CONNACK means "not now" rather than "not ever".
    ///
    /// `quotaExceeded` is BMW's way of saying the one connection their account allows is
    /// already taken — confirmed by watching a second client get exactly this code while
    /// the first held the stream. `notAuthorized` is kept here too: the token is refreshed
    /// immediately before connecting, so bad credentials are the unlikely reading, and
    /// retrying is the safer way to be wrong.
    static func isContention(_ ack: CocoaMQTTCONNACKReasonCode) -> Bool {
        switch ack {
        case .quotaExceeded, .serverBusy, .notAuthorized, .badUsernameOrPassword: return true
        default: return false
        }
    }

    /// Reports what the broker allowed, once. Must be called on `queue`.
    private func reportVerdict(_ supported: Bool) {
        guard requestedMode.isPersistent, !verdictReported else { return }
        verdictReported = true
        onPersistentSessionVerdict?(supported)
    }

    public func mqtt5(
        _ mqtt5: CocoaMQTT5,
        didReceiveMessage message: CocoaMQTT5Message,
        id: UInt16,
        publishData: MqttDecodePublish?
    ) {
        // BMW keeps extending the descriptor catalogue, so an unparseable frame is
        // dropped rather than treated as fatal.
        guard let decoded = try? JSONDecoder()
            .decode(StreamMessage.self, from: Data(message.payload))
        else { return }

        // Every message carries its VIN, so a wildcard subscription discovers it
        // without a `mappings` call.
        if let discovered = decoded.vin ?? Self.vin(fromTopic: message.topic) {
            if discoveredVIN != discovered {
                discoveredVIN = discovered
                onVINDiscovered?(discovered)
            }
            // With a wildcard subscription, ignore other vehicles on the account.
            if let vin, discovered != vin { return }
        }
        continuation?.yield(decoded)
    }

    public func mqtt5DidDisconnect(_ mqtt5: CocoaMQTT5, withError err: Error?) {
        guard !isRotatingToken, !isStopping else { return }
        if case .refused = _status { return }
        setStatus(.disconnected(err.map { String(describing: $0) }))
    }

    // Unused delegate callbacks.
    public func mqtt5(_ m: CocoaMQTT5, didPublishMessage message: CocoaMQTT5Message, id: UInt16) {}
    public func mqtt5(_ m: CocoaMQTT5, didPublishAck id: UInt16, pubAckData: MqttDecodePubAck?) {}
    public func mqtt5(_ m: CocoaMQTT5, didPublishRec id: UInt16, pubRecData: MqttDecodePubRec?) {}
    public func mqtt5(
        _ m: CocoaMQTT5,
        didSubscribeTopics success: NSDictionary,
        failed: [String],
        subAckData: MqttDecodeSubAck?
    ) {}
    public func mqtt5(
        _ m: CocoaMQTT5,
        didUnsubscribeTopics topics: [String],
        unsubAckData: MqttDecodeUnsubAck?
    ) {}
    public func mqtt5(
        _ m: CocoaMQTT5,
        didReceiveDisconnectReasonCode reasonCode: CocoaMQTTDISCONNECTReasonCode
    ) {}
    public func mqtt5(
        _ m: CocoaMQTT5,
        didReceiveAuthReasonCode reasonCode: CocoaMQTTAUTHReasonCode
    ) {}
    public func mqtt5DidPing(_ m: CocoaMQTT5) {}
    public func mqtt5DidReceivePong(_ m: CocoaMQTT5) {}
}
