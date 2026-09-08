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
/// REST is reached two ways, both bounded: the user pressing "Fetch now", and an
/// optional idle poll that fills the gaps when the car goes quiet (see `startPolling`).
/// Both are labelled with their cost, and the poll spends only non-essential budget.
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

    /// The charge to show, refreshed on a ticker so the estimate advances between the
    /// car's reports.
    ///
    /// This lives on the model rather than in a `TimelineView` because a TimelineView
    /// inside the `MenuBarExtra` *label* wedges SwiftUI in `updateButton` while it
    /// builds the status item, blocking the main thread hard enough that
    /// `applicationDidFinishLaunching` never returns and the app never starts.
    public private(set) var displayChargePercent: Double?
    public private(set) var isChargeEstimated = false

    public private(set) var notifications = NotificationPreferences.default
    public private(set) var polling = PollingPreferences.default
    /// When the stream last delivered anything, for deciding the car has gone quiet.
    public private(set) var lastStreamMessageAt: Date?
    public private(set) var lastAutoFetchAt: Date?
    /// Set when an automatic poll was skipped for want of budget, so the panel can say
    /// so quietly instead of raising it as a failure.
    public private(set) var pollingBlockedReason: String?
    public private(set) var notifier = ChargingNotifier()
    /// What the app was in a position to hear, and when it was not. This is what lets the
    /// panel tell "the car is quiet" apart from "we were asleep".
    public let coverage: CoverageTracker

    private var session: Session?
    private var stream: CarDataStream?
    private var pumpTask: Task<Void, Never>?
    private let stateStore = VehicleStateStore()
    private let sampleLog = SampleLog()
    private var pollTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var backlogTask: Task<Void, Never>?
    private let systemWatcher = SystemWatcher()
    /// Resyncs spent today, held in memory: the daily cap is a courtesy limit and
    /// `QuotaTracker`'s reserve is the real backstop.
    private var resyncsToday = 0
    private var resyncDay = ""
    /// Plenty for the 24 h sparkline and recent sessions, while keeping the in-memory
    /// array bounded no matter how long the 90-day log grows.
    nonisolated static let samplesKeptInMemory = 5_000

    /// Keeps the in-memory window bounded however large the on-disk log grows.
    nonisolated static func trimmed(_ samples: [Sample]) -> [Sample] {
        samples.count > samplesKeptInMemory
            ? Array(samples.suffix(samplesKeptInMemory))
            : samples
    }
    private let launchedAt = Date()

    public init() {
        coverage = CoverageTracker()
        let config = Config.load()
        notifications = config.notificationPreferences
        polling = config.pollingPreferences
    }

    /// A ready-to-render model with synthetic state and no network, for rendering the
    /// panel to an image (`--cli render`) and for previews. Nothing here connects.
    /// - Parameter previewGap: stages an unresolved coverage gap, so the states that only
    ///   appear after the Mac has been away can be rendered without waiting for a real one.
    public init(
        previewValues: [String: TelematicValue],
        vehicleName: String? = "BMW i4 eDrive35",
        samples: [Sample] = [],
        streamStatus: CarDataStream.Status = .connected,
        previewGap: TimeInterval? = nil
    ) {
        // Without a staged gap the preview is meant to look healthy, so coverage reaches
        // back far enough to vouch for the sample values.
        coverage = CoverageTracker(
            store: .ephemeral,
            now: Date().addingTimeInterval(previewGap == nil ? -30 * 24 * 3600 : 0)
        )
        notifications = .default
        vehicle.vehicleName = vehicleName
        vehicle.merge(previewValues)
        recentSamples = Self.trimmed(samples)
        self.streamStatus = streamStatus
        quota = QuotaSnapshot(used: 36, limit: QuotaTracker.dailyLimit, resetsAt: Date().addingTimeInterval(3600))
        phase = .ready
        displayChargePercent = vehicle.displayChargePercent()
        isChargeEstimated = vehicle.isChargeEstimated()
        let now = Date()
        if let previewGap {
            coverage.endListening(cause: .sleep, at: now.addingTimeInterval(-previewGap))
            coverage.beginListening(at: now)
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        Log.app.notice("start")
        guard Config.resolvedClientID() != nil else {
            Log.app.notice("no client id")
            phase = .needsClientID
            return
        }
        do {
            let session = try Session.make()
            self.session = session

            guard await session.tokens.hasCredentials() else {
                Log.app.notice("no credentials")
                phase = .needsAuthorization
                return
            }
            Log.app.notice("credentials ok, requesting notification authorisation")
            await notifier.requestAuthorizationIfNeeded(for: notifications)
            Log.app.notice("notification authorisation done, connecting")
            try await connect(using: session)
        } catch {
            Log.app.error("start failed: \(String(describing: error), privacy: .public)")
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
        stopAmbientWork()
        try? FileTokenStorage().clear()
        try? KeychainTokenStorage().clear()
        stateStore.clear()
        session = nil
        phase = .needsAuthorization
    }

    /// Fetches one REST snapshot, costing a call from BMW's 50/day and lazily creating
    /// the telemetry container if setup never ran.
    ///
    /// - Parameter automatic: a background idle poll rather than a press. Automatic
    ///   fetches spend non-essential budget, so they stop at the reserve and can never
    ///   consume the headroom a manual fetch relies on. Their failures are also
    ///   reported quietly — a poll that can't run is not an error the user caused.
    public func refreshSnapshot(automatic: Bool = false) async {
        guard let session else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            let setup = try await session.bootstrap()
            vehicle.vin = setup.vin
            if vehicle.vehicleName == nil { vehicle.vehicleName = setup.vehicleName }

            let snapshot = try await session.client.telematicData(
                vin: setup.vin,
                containerID: setup.containerID,
                essential: !automatic
            )
            if automatic { lastAutoFetchAt = Date() }
            Log.api.notice("snapshot: \(snapshot.count, privacy: .public) values, automatic=\(automatic, privacy: .public)")
            if !snapshot.isEmpty {
                vehicle.merge(snapshot)
                restoredFrom = nil
                snapshotError = nil
                pollingBlockedReason = nil
                stateStore.save(vehicle.values)
                // A snapshot counts as hearing from the car, so the idle clock restarts.
                lastStreamMessageAt = Date()
                // The hole has been answered as far as a snapshot can answer it. Which
                // descriptors it actually refreshed is left to speak for itself: each
                // carries BMW's own timestamp, so anything the container does not cover
                // simply stays unconfirmed.
                coverage.resolveGap()
            }
        } catch {
            if automatic {
                Log.polling.error("fetch failed: \(String(describing: error), privacy: .public)")
                pollingBlockedReason = String(describing: error)
                lastAutoFetchAt = Date()
            } else {
                snapshotError = String(describing: error)
            }
        }
        quota = await session.client.quotaSnapshot()
    }

    /// Recomputes the displayed charge from the current time.
    private func refreshEstimate(now: Date = Date()) {
        displayChargePercent = vehicle.displayChargePercent(asOf: now)
        isChargeEstimated = vehicle.isChargeEstimated(asOf: now)
    }

    /// Advances the estimate while the car is silent. Cheap: one wake every 30 s, and
    /// only the two published values change.
    private func startEstimateTicker() {
        estimateTask?.cancel()
        estimateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshEstimate()
            }
        }
    }

    // MARK: - Coverage, sleep and wake

    /// A message this old was published before we reconnected, so it is the broker
    /// replaying a backlog rather than the car speaking now.
    static let backlogThreshold: TimeInterval = 2 * 60
    /// How long the backlog is allowed to keep arriving before it is considered settled.
    static let backlogSettle: TimeInterval = 3
    /// How long to wait after a wake for the broker to replay, before concluding it will
    /// not and spending a call instead.
    static let resyncGrace: TimeInterval = 45

    public func isBacklog(_ message: StreamMessage, now: Date = Date()) -> Bool {
        guard let sentAt = message.sentAt else { return false }
        return now.timeIntervalSince(sentAt) > Self.backlogThreshold
    }

    private func startWatchingSystem() {
        systemWatcher.onSleep = { [weak self] in self?.handleSleep() }
        systemWatcher.onWake = { [weak self] in self?.handleWake() }
        systemWatcher.onNetworkChange = { [weak self] up in self?.handleNetworkChange(up: up) }
        systemWatcher.start()
    }

    private func handleSleep() {
        coverage.endListening(cause: .sleep)
        // Disconnecting deliberately is not the same as vanishing: a clean DISCONNECT
        // leaves the persistent session — and whatever the broker queues into it — alive,
        // where a socket left to rot is torn down by BMW's 60 s idle timeout.
        stream?.pause()
    }

    private func handleWake() {
        Log.app.notice("wake: gap \(Int(self.coverage.openGapDuration() ?? 0), privacy: .public)s")
        stream?.resume()
        scheduleResyncCheck()
    }

    private func handleNetworkChange(up: Bool) {
        if up {
            stream?.reconnectNow()
            scheduleResyncCheck()
        } else {
            coverage.endListening(cause: .network)
        }
    }

    /// Waits out the grace period, then decides whether the hole still needs a call.
    ///
    /// The wait is the point: if BMW held our session, the backlog lands within seconds
    /// of reconnecting and there is nothing left to buy.
    private func scheduleResyncCheck() {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.resyncGrace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.resyncIfGapUnfilled()
        }
    }

    private func resyncIfGapUnfilled(now: Date = Date()) async {
        guard polling.enabled, polling.resyncAfterGap, phase == .ready, !isFetching else { return }
        // Never let this trigger first-time setup: that would spend ~3 calls unasked.
        guard Config.load().containerID != nil else { return }
        guard let gap = coverage.unresolvedGap(minimum: Double(polling.gapMinutes) * 60) else {
            Log.polling.debug("resync: no unresolved gap")
            return
        }

        let today = Self.utcDay(now)
        if resyncDay != today {
            resyncDay = today
            resyncsToday = 0
        }
        guard resyncsToday < polling.maxResyncsPerDay else {
            Log.polling.notice("resync: daily cap of \(self.polling.maxResyncsPerDay, privacy: .public) reached")
            return
        }

        resyncsToday += 1
        Log.polling.notice("resync: \(gap.shortDuration, privacy: .public) \(gap.cause.reason, privacy: .public), fetching")
        await refreshSnapshot(automatic: true)
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// Stops the work that outlives any single connection.
    ///
    /// Deliberately separate from `stopStream()`: that runs every time the stream is
    /// rebuilt, and folding these in meant `connect()` installed the watcher and heartbeat
    /// and then `startStream()` immediately cancelled them — the sleep and wake handling
    /// was never armed at all.
    private func stopAmbientWork() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        resyncTask?.cancel()
        resyncTask = nil
        systemWatcher.stop()
    }

    /// Keeps the on-disk heartbeat current, so the next launch can size the hole this run
    /// leaves behind when the app is quit or killed.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(CoverageStore.heartbeat * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.coverage.heartbeat()
            }
        }
    }

    // MARK: - Idle polling

    public func updatePolling(_ preferences: PollingPreferences) {
        polling = preferences
        var config = Config.load()
        config.pollingPreferences = preferences
        try? config.save()
        startPolling()
    }

    /// How long the car has been silent, for the settings screen.
    public func streamIdleInterval(asOf now: Date = Date()) -> TimeInterval? {
        guard let since = lastStreamMessageAt else { return nil }
        return now.timeIntervalSince(since)
    }

    /// Watches for stream silence and fetches a snapshot to fill the gap.
    ///
    /// CarData publishes on events, not on a clock, so a charge can climb for half an
    /// hour with nothing sent. This is the only thing in the app that spends BMW's
    /// budget without a click, which is why it is a setting, is non-essential, and
    /// refuses to run before setup has cached a container.
    private func startPolling() {
        pollTask?.cancel()
        guard polling.enabled, polling.chargingIdleMinutes > 0 else {
            pollTask = nil
            Log.polling.notice("disabled")
            return
        }
        Log.polling.notice("armed: fetch after \(self.polling.chargingIdleMinutes, privacy: .public) min of silence while charging")

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Checking each minute keeps the decision responsive without the timer
                // itself costing anything.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.pollIfIdle()
            }
        }
    }

    private func pollIfIdle(now: Date = Date()) async {
        guard polling.enabled, phase == .ready, !isFetching else {
            Log.polling.debug("tick skipped: enabled=\(self.polling.enabled, privacy: .public) ready=\(self.phase == .ready, privacy: .public) fetching=\(self.isFetching, privacy: .public)")
            return
        }
        // Charging is the only time the number moves on its own, so it is the only time
        // a fetch buys anything. A parked car polled all day would spend the whole
        // budget to learn it is still parked.
        guard vehicle.isCharging else {
            Log.polling.debug("tick skipped: not charging")
            return
        }
        // Never let a poll trigger first-time setup: that would spend ~3 calls the user
        // never asked for.
        guard Config.load().containerID != nil else {
            Log.polling.debug("tick skipped: no container cached")
            return
        }

        let idleSince = max(
            lastStreamMessageAt ?? .distantPast,
            lastAutoFetchAt ?? .distantPast
        )
        // Nothing heard at all yet: measure from launch rather than fetching instantly.
        let reference = idleSince == .distantPast ? launchedAt : idleSince
        let idle = now.timeIntervalSince(reference)
        guard idle >= Double(polling.chargingIdleMinutes) * 60 else {
            Log.polling.debug("tick: charging, idle \(Int(idle), privacy: .public)s of \(self.polling.chargingIdleMinutes * 60, privacy: .public)s")
            return
        }

        Log.polling.notice("fetching after \(Int(idle), privacy: .public)s of silence while charging")
        await refreshSnapshot(automatic: true)
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
        recentSamples = Self.trimmed(sampleLog.load())

        refreshEstimate()
        startEstimateTicker()

        // Time the app was not running is a hole like any other, and the heartbeat the
        // last run left behind is the only record of when it started.
        coverage.seedFromPreviousRun()

        startStream(session: session, vin: config.vin)
        startHeartbeat()
        startWatchingSystem()
        phase = .ready
        Log.app.notice("ready: vin=\(config.vin != nil, privacy: .public) cached=\(self.vehicle.values.count, privacy: .public) values")
        startPolling()
    }

    private func startStream(session: Session, vin: String?) {
        stopStream()

        // A persistent session is what turns a night of sleep from "everything lost" into
        // "replayed on reconnect". BMW does not document whether they allow it, so it is
        // asked for, and the answer is remembered (see `--cli session-test`).
        let mode: CarDataStream.SessionMode = Config.load().shouldTryPersistentSession
            ? .persistent(
                clientID: Config.resolvedStreamClientID(),
                expiry: CarDataStream.sessionExpiry
            )
            : .clean

        let stream = CarDataStream(tokens: session.tokens, vin: vin, mode: mode)
        stream.onStatusChange = { [weak self] status in
            Log.stream.notice("\(status.summary, privacy: .public)")
            Task { @MainActor in self?.applyStreamStatus(status) }
        }
        stream.onVINDiscovered = { [weak self] discovered in
            Task { @MainActor in self?.adoptDiscoveredVIN(discovered) }
        }
        stream.onPersistentSessionVerdict = { supported in
            Log.stream.notice("persistent session \(supported ? "accepted" : "refused", privacy: .public)")
            Config.recordPersistentSession(supported)
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

    /// Mirrors the stream's connection state into coverage, which is where liveness stops
    /// being cosmetic: losing the connection is the moment the car can start changing
    /// without us.
    private func applyStreamStatus(_ status: CarDataStream.Status) {
        streamStatus = status
        switch status {
        case .connected:
            // A persistent session means the broker held our subscription across the hole,
            // so anything published was queued and is arriving now — our knowledge is
            // continuous even though the connection was not. That only holds while the
            // session itself lived: past its expiry BMW has discarded it along with the
            // queue, and the hole is real.
            let gap = coverage.openGapDuration() ?? 0
            let covered = (stream?.sessionMode.isPersistent ?? false)
                && gap < Double(CarDataStream.sessionExpiry)
            coverage.beginListening(gapCovered: covered)
        case .disconnected, .refused:
            coverage.endListening(cause: .disconnected)
        case .idle, .connecting:
            break
        }
    }

    private func apply(_ message: StreamMessage) {
        let now = Date()
        let backlog = isBacklog(message, now: now)

        vehicle.merge(message.data)
        restoredFrom = nil
        lastStreamMessageAt = now
        pollingBlockedReason = nil
        Log.stream.debug("message: \(message.data.count, privacy: .public) descriptor(s)\(backlog ? " (backlog)" : "")")
        refreshEstimate()

        if backlog {
            // A replayed backlog is history, not news. Firing the detector per message
            // would post a banner for every transition BMW queued overnight — "charging
            // started" at 02:14, "finished" at 04:31 — all at once, at breakfast. So the
            // backlog is absorbed silently and the detector runs once over the settled
            // state; being transition-based, that yields the net change and nothing else.
            scheduleBacklogSettle()
        } else {
            // One detector drives both the banner and the matching on-screen pulse, so the
            // two can never disagree about what happened.
            raiseEvents()
        }

        // Local history is what makes BMW's REST chargingHistory endpoint unnecessary.
        // Appending in memory rather than re-reading the file: `load()` parses every
        // line, and doing that per message meant a burst re-parsed the whole 90-day log
        // dozens of times in a second. Replayed messages are recorded at the time the car
        // published them, so the sparkline fills the gap in properly rather than stacking
        // a night's worth of readings onto the moment we woke up.
        let sample = Sample(vehicle, at: backlog ? (message.sentAt ?? now) : now)
        if sampleLog.record(sample) {
            recentSamples = Self.trimmed(recentSamples + [sample])
        }
        scheduleStateSave()
    }

    private func raiseEvents() {
        let events = notifier.process(vehicle, preferences: notifications)
        if let cue = events.compactMap(TransientCue.init).first {
            transientCue = cue
        }
    }

    /// Runs the detector once, `backlogSettle` seconds after the last replayed message.
    private func scheduleBacklogSettle() {
        backlogTask?.cancel()
        backlogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.backlogSettle * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            Log.stream.notice("backlog settled; raising net events")
            self.raiseEvents()
            // The broker replayed what we missed, so the hole is answered.
            self.coverage.resolveGap()
        }
    }

    /// The on-disk cache only needs to be current enough to survive a relaunch, so
    /// writes are coalesced instead of encoding the whole state per message.
    private func scheduleStateSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stateStore.save(self.vehicle.values)
        }
    }

    /// Called by the view once a cue has been animated.
    public func consumeCue() { transientCue = nil }

    /// Charging sessions reconstructed from the local log — no API calls.
    public var chargingSessions: [ChargingSession] {
        ChargingSessionBuilder.sessions(from: recentSamples).reversed()
    }

    private func stopStream() {
        // A coalesced write may still be pending; do it now rather than lose it.
        saveTask?.cancel()
        saveTask = nil
        if !vehicle.values.isEmpty { stateStore.save(vehicle.values) }
        pollTask?.cancel()
        pollTask = nil
        estimateTask?.cancel()
        estimateTask = nil
        backlogTask?.cancel()
        backlogTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        stream?.stop()
        stream = nil
        streamStatus = .idle
    }
}
