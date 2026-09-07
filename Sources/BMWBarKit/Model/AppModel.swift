import Foundation
import Observation

/// Drives the status bar app.
///
/// **Streaming is the only data source.** BMW caps REST at 50 calls a day and points
/// at streaming for anything frequent, so nothing here calls REST at all: the VIN is
/// discovered from the stream's wildcard topic, and a telemetry container — which only
/// ever fed the REST snapshot endpoint — is never created. The last known state is
/// restored from disk so the panel has content instantly, and the stream corrects it.
///
/// The single remaining REST path is the user explicitly pressing "Fetch now", which
/// is labelled with its cost.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        /// No client ID yet — the BMW portal setup has not been done.
        case needsClientID
        /// Client ID present, but this Mac has not been approved.
        case needsAuthorization
        /// Waiting for the user to approve in the browser.
        case awaitingApproval(userCode: String, url: URL)
        case connecting
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .connecting
    public let vehicle = VehicleState()
    public private(set) var streamStatus: CarDataStream.Status = .idle
    public private(set) var quota: QuotaSnapshot?
    /// Set when the launch snapshot could not be fetched, so the panel can say why
    /// it is showing nothing yet while the stream still works.
    public private(set) var snapshotError: String?
    /// When the cached state on disk was written, if that is what is on screen.
    public private(set) var restoredFrom: Date?
    /// True while an explicit "Fetch now" is in flight.
    public private(set) var isFetching = false

    /// Nothing has ever been heard from this car, so the panel has nothing to show
    /// and should offer the one-call fetch.
    public var isAwaitingFirstReport: Bool {
        vehicle.values.isEmpty && phase == .ready
    }

    /// Current colour and continuous motion, derived from vehicle state.
    public var mood: VehicleMood { VehicleMood.from(vehicle) }
    /// A one-shot animation awaiting playback. The view clears it via `consumeCue()`.
    public private(set) var transientCue: TransientCue?
    /// Recent history for the sparkline, refreshed as samples are recorded.
    public private(set) var recentSamples: [Sample] = []

    public private(set) var notifications = NotificationPreferences.default
    public private(set) var notifier = ChargingNotifier()

    private var session: Session?
    private var stream: CarDataStream?
    private var pumpTask: Task<Void, Never>?
    private let stateStore = VehicleStateStore()
    private let sampleLog = SampleLog()

    public init() {
        notifications = Config.load().notificationPreferences
    }

    /// A ready-to-render model with synthetic state and no network, for rendering the
    /// panel to an image (`--cli render`) and for previews. Nothing here connects.
    public init(
        previewValues: [String: TelematicValue],
        vehicleName: String? = "BMW i4 eDrive35",
        samples: [Sample] = [],
        streamStatus: CarDataStream.Status = .connected
    ) {
        notifications = .default
        vehicle.vehicleName = vehicleName
        vehicle.merge(previewValues)
        recentSamples = samples
        self.streamStatus = streamStatus
        quota = QuotaSnapshot(used: 36, limit: QuotaTracker.dailyLimit, resetsAt: Date().addingTimeInterval(3600))
        phase = .ready
    }

    // MARK: - Lifecycle

    public func start() async {
        guard Config.resolvedClientID() != nil else {
            phase = .needsClientID
            return
        }
        do {
            let session = try Session.make()
            self.session = session

            guard await session.tokens.hasCredentials() else {
                phase = .needsAuthorization
                return
            }
            await notifier.requestAuthorizationIfNeeded(for: notifications)
            try await connect(using: session)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Runs the device code flow. `phase` reports the code to show the user.
    public func authorize(clientID: String) async {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = Session(clientID: trimmed)
        self.session = session
        do {
            let pkce = PKCE()
            let grant = try await session.auth.requestDeviceCode(pkce: pkce)
            phase = .awaitingApproval(userCode: grant.userCode, url: grant.verificationURI)

            let tokens = try await session.auth.pollForTokens(grant: grant, pkce: pkce)
            try await session.tokens.adopt(tokens)

            var config = Config.load()
            config.clientID = trimmed
            try config.save()

            await notifier.requestAuthorizationIfNeeded(for: notifications)
            try await connect(using: session)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    public func signOut() async {
        stopStream()
        try? FileTokenStorage().clear()
        try? KeychainTokenStorage().clear()
        stateStore.clear()
        session = nil
        phase = .needsAuthorization
    }

    /// The only REST path left, and only ever on an explicit press. Costs one call
    /// from BMW's 50/day, and lazily creates the telemetry container it needs — which
    /// is why the container is not made at startup.
    public func refreshSnapshot() async {
        guard let session else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            let setup = try await session.bootstrap()
            vehicle.vin = setup.vin
            if vehicle.vehicleName == nil { vehicle.vehicleName = setup.vehicleName }

            let snapshot = try await session.client.telematicData(
                vin: setup.vin,
                containerID: setup.containerID
            )
            if !snapshot.isEmpty {
                vehicle.merge(snapshot)
                restoredFrom = nil
                snapshotError = nil
                stateStore.save(vehicle.values)
            }
        } catch {
            snapshotError = String(describing: error)
        }
        quota = await session.client.quotaSnapshot()
    }

    /// The stream told us which car this is, so record it and never ask BMW.
    private func adoptDiscoveredVIN(_ vin: String) {
        guard vehicle.vin != vin else { return }
        vehicle.vin = vin
        var config = Config.load()
        config.vin = vin
        try? config.save()
    }

    // MARK: - Notification preferences

    public func updateNotifications(_ preferences: NotificationPreferences) {
        notifications = preferences
        var config = Config.load()
        config.notificationPreferences = preferences
        try? config.save()

        Task { await notifier.requestAuthorizationIfNeeded(for: preferences) }
    }

    // MARK: - Connection

    private func connect(using session: Session) async throws {
        phase = .connecting

        // Nothing is fetched. The VIN comes from the stream, the name from config, and
        // the values from the on-disk cache until the car next reports.
        let config = Config.load()
        vehicle.vin = config.vin
        vehicle.vehicleName = config.vehicleName

        if let cached = stateStore.load() {
            vehicle.merge(cached.values, receivedAt: cached.savedAt)
            restoredFrom = cached.savedAt
        }
        quota = await session.client.quotaSnapshot()

        // Seed the detector with the restored state so the first live message is
        // compared against reality, not against an empty baseline.
        notifier.process(vehicle, preferences: notifications)

        sampleLog.prune()
        recentSamples = sampleLog.load()

        startStream(session: session, vin: config.vin)
        phase = .ready
    }

    private func startStream(session: Session, vin: String?) {
        stopStream()

        let stream = CarDataStream(tokens: session.tokens, vin: vin)
        stream.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.streamStatus = status }
        }
        stream.onVINDiscovered = { [weak self] discovered in
            Task { @MainActor in self?.adoptDiscoveredVIN(discovered) }
        }
        self.stream = stream

        let messages = stream.messages()
        stream.start()

        pumpTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                await MainActor.run { self.apply(message) }
            }
        }
    }

    private func apply(_ message: StreamMessage) {
        vehicle.merge(message.data)
        restoredFrom = nil

        // One detector drives both the banner and the matching on-screen pulse, so the
        // two can never disagree about what happened.
        let events = notifier.process(vehicle, preferences: notifications)
        if let cue = events.compactMap(TransientCue.init).first {
            transientCue = cue
        }

        // Local history is what makes BMW's REST chargingHistory endpoint unnecessary.
        if sampleLog.record(Sample(vehicle)) {
            recentSamples = sampleLog.load()
        }
        stateStore.save(vehicle.values)
    }

    /// Called by the view once a cue has been animated.
    public func consumeCue() { transientCue = nil }

    /// Charging sessions reconstructed from the local log — no API calls.
    public var chargingSessions: [ChargingSession] {
        ChargingSessionBuilder.sessions(from: recentSamples).reversed()
    }

    private func stopStream() {
        pumpTask?.cancel()
        pumpTask = nil
        stream?.stop()
        stream = nil
        streamStatus = .idle
    }
}
