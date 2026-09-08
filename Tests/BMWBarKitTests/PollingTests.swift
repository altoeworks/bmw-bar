import Foundation
import Testing
@testable import BMWBarKit

@Suite("Charging-only polling preferences")
struct PollingPreferencesTests {
    /// Polling is confined to charging, so cost per charging hour is the figure that
    /// means something — a parked day now costs nothing at all.
    @Test func reportsCostPerChargingHour() {
        #expect(PollingPreferences(chargingIdleMinutes: 15).callsPerHourWhileCharging == 4)
        #expect(PollingPreferences(chargingIdleMinutes: 30).callsPerHourWhileCharging == 2)
        #expect(PollingPreferences(chargingIdleMinutes: 5).callsPerHourWhileCharging == 12)
    }

    /// A long charge must stay well inside the daily budget.
    @Test func aTypicalChargeStaysCheap() {
        let cost = PollingPreferences.default.calls(forChargeLasting: 3)
        #expect(cost == 12)
        #expect(cost < QuotaTracker.dailyLimit - QuotaTracker.reserve)
    }

    /// Even an implausibly long charge cannot exhaust the budget on its own.
    @Test func evenAnAllDayChargeFitsTheBudget() {
        let cost = PollingPreferences.default.calls(forChargeLasting: 10)
        #expect(cost <= QuotaTracker.dailyLimit - QuotaTracker.reserve)
    }

    @Test func aZeroIntervalCannotDivideByZero() {
        #expect(PollingPreferences(chargingIdleMinutes: 0).callsPerHourWhileCharging == 0)
    }

    /// Same lesson as the notification preferences: a new field must not orphan an
    /// existing config, because Config.load() falls back to empty on any decode error.
    @Test func decodesAConfigWrittenBeforePollingExisted() throws {
        let legacy = #"{"clientID":"abc","vin":"V","notifications":{"chargingStarted":true}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
        #expect(config.clientID == "abc")
        #expect(config.pollingPreferences == .default)
    }

    /// The interval was called `idleMinutes` before polling became charging-only; a
    /// config written then should keep the interval the user chose.
    @Test func migratesTheOldIntervalKey() throws {
        let old = #"{"clientID":"abc","polling":{"enabled":true,"idleMinutes":45}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.pollingPreferences.chargingIdleMinutes == 45)
        #expect(config.pollingPreferences.enabled)
    }

    @Test func decodesPartialPollingPreferences() throws {
        let partial = #"{"clientID":"abc","polling":{"enabled":false}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(partial.utf8))
        #expect(!config.pollingPreferences.enabled)
        #expect(config.pollingPreferences.chargingIdleMinutes == 15)
    }

    /// The gap-resync settings arrived after charging-only polling. A config written in
    /// between must keep its interval and pick up the new defaults, not reset to nothing —
    /// the same trap that once silently discarded a saved client ID.
    @Test func decodesAConfigWrittenBeforeGapResyncExisted() throws {
        let old = #"{"clientID":"abc","polling":{"enabled":true,"chargingIdleMinutes":25}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.clientID == "abc")
        #expect(config.pollingPreferences.chargingIdleMinutes == 25)
        #expect(config.pollingPreferences.resyncAfterGap)
        #expect(config.pollingPreferences.gapMinutes == 60)
        #expect(config.pollingPreferences.maxResyncsPerDay == 4)
    }

    @Test func roundTripsTheResyncSettings() throws {
        let preferences = PollingPreferences(
            enabled: true,
            chargingIdleMinutes: 20,
            resyncAfterGap: false,
            gapMinutes: 120,
            maxResyncsPerDay: 2
        )
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(PollingPreferences.self, from: data) == preferences)
    }

    @Test func roundTrips() throws {
        let preferences = PollingPreferences(enabled: false, chargingIdleMinutes: 20)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(PollingPreferences.self, from: data) == preferences)
    }
}

@Suite("Idle polling budget safety")
struct PollingBudgetTests {
    private func tracker() -> QuotaTracker {
        QuotaTracker(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-\(UUID().uuidString).json"))
    }

    /// The critical guarantee: a background poll must never eat the headroom that a
    /// manual "Fetch now" depends on.
    @Test func automaticPollsStopBeforeStarvingManualFetches() async throws {
        let quota = tracker()
        let usableByPolling = QuotaTracker.dailyLimit - QuotaTracker.reserve
        for _ in 0..<usableByPolling { try await quota.consume(essential: false) }

        // Further automatic polls are refused...
        await #expect(throws: QuotaTracker.Error.self) {
            try await quota.consume(essential: false)
        }
        // ...while the user can still fetch by hand.
        try await quota.consume(essential: true)
        #expect(await quota.snapshot().remaining == QuotaTracker.reserve - 1)
    }

    /// A full day of polling on a silent car must still leave the reserve intact.
    @Test func aFullDayOfPollingLeavesTheReserve() async throws {
        let quota = tracker()
        var spent = 0
        for _ in 0..<QuotaTracker.dailyLimit {
            do {
                try await quota.consume(essential: false)
                spent += 1
            } catch {
                break
            }
        }
        #expect(spent == QuotaTracker.dailyLimit - QuotaTracker.reserve)
        #expect(await quota.snapshot().remaining == QuotaTracker.reserve)
    }
}

/// Whether to ask BMW to hold our session, and how the answer is remembered.
///
/// The point of caching the answer is to stop paying for a doomed round trip on every
/// launch — but a cached "no" that is never revisited would outlive whatever made it true.
@Suite("Persistent session policy")
struct PersistentSessionPolicyTests {
    @Test func anUntestedConfigTries() {
        #expect(Config().shouldTryPersistentSession)
    }

    @Test func aKnownYesKeepsTrying() {
        let config = Config(persistentSession: true, persistentSessionTestedAt: Date())
        #expect(config.shouldTryPersistentSession)
    }

    @Test func aRecentNoIsBelieved() {
        let config = Config(
            persistentSession: false,
            persistentSessionTestedAt: Date().addingTimeInterval(-3600)
        )
        #expect(!config.shouldTryPersistentSession)
    }

    @Test func aStaleNoIsRetested() {
        let old = Date().addingTimeInterval(-Config.persistentSessionRetestInterval - 60)
        let config = Config(persistentSession: false, persistentSessionTestedAt: old)
        #expect(config.shouldTryPersistentSession)
    }

    /// A "no" with no date attached cannot be trusted to be recent, so it is retried
    /// rather than believed forever.
    @Test func anUndatedNoIsRetested() {
        #expect(Config(persistentSession: false).shouldTryPersistentSession)
    }

    @Test func sessionModeReportsItself() {
        #expect(CarDataStream.SessionMode.persistent(clientID: "a", expiry: 60).isPersistent)
        #expect(!CarDataStream.SessionMode.clean.isPersistent)
    }
}
