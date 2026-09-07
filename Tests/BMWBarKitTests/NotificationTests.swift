import Foundation
import Testing
@testable import BMWBarKit

@Suite("Charging event detection")
struct ChargingEventDetectorTests {
    private func state(
        status: String? = nil,
        percent: Double? = nil,
        plugged: Bool? = nil
    ) -> VehicleState {
        let state = VehicleState()
        var values: [String: TelematicValue] = [:]
        if let status { values[Descriptor.chargingStatus] = TelematicValue(raw: .string(status)) }
        if let percent { values[Descriptor.socDisplayed] = TelematicValue(raw: .number(percent)) }
        if let plugged { values[Descriptor.plugged] = TelematicValue(raw: .bool(plugged)) }
        state.merge(values)
        return state
    }

    private let now = Date(timeIntervalSince1970: 1_788_782_400)

    /// The launch baseline must be silent — otherwise every start-up would announce a
    /// charge that began hours ago.
    @Test func firstUpdateEstablishesBaselineSilently() {
        var detector = ChargingEventDetector()
        let events = detector.update(
            state(status: "CHARGINGACTIVE", percent: 50, plugged: true),
            preferences: .default,
            now: now
        )
        #expect(events.isEmpty)
    }

    @Test func detectsChargingStart() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: .default, now: now)
        let events = detector.update(
            state(status: "CHARGINGACTIVE", percent: 40, plugged: true),
            preferences: .default,
            now: now
        )
        #expect(events == [.started(percent: 40)])
    }

    /// The stream is sparse — most messages change nothing relevant and must be quiet.
    @Test func repeatedIdenticalUpdatesDoNotRepeatEvents() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: .default, now: now)
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 40, plugged: true), preferences: .default, now: now)

        for _ in 0..<5 {
            let events = detector.update(
                state(status: "CHARGINGACTIVE", percent: 41, plugged: true),
                preferences: .default,
                now: now
            )
            #expect(events.isEmpty)
        }
    }

    /// BMW says CHARGINGENDED when it stops at the configured limit, and
    /// FINISHED_FULLY_CHARGED only when the pack is actually full.
    @Test func distinguishesLimitReachedFromBatteryFull() {
        var atLimit = ChargingEventDetector()
        _ = atLimit.update(state(status: "CHARGINGACTIVE", percent: 79, plugged: true), preferences: .default, now: now)
        #expect(
            atLimit.update(state(status: "CHARGINGENDED", percent: 80, plugged: true), preferences: .default, now: now)
                == [.finished(percent: 80, reachedLimit: true)]
        )

        var full = ChargingEventDetector()
        _ = full.update(state(status: "CHARGING", percent: 99, plugged: true), preferences: .default, now: now)
        #expect(
            full.update(state(status: "FINISHED_FULLY_CHARGED", percent: 100, plugged: true), preferences: .default, now: now)
                == [.finished(percent: 100, reachedLimit: false)]
        )
    }

    @Test func detectsInterruption() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 55, plugged: true), preferences: .default, now: now)
        let events = detector.update(
            state(status: "CHARGINGERROR", percent: 55, plugged: true),
            preferences: .default,
            now: now
        )
        #expect(events == [.interrupted(status: .error, percent: 55)])
    }

    /// Charging stopping because the cable came out is normal, not an interruption.
    @Test func unpluggingIsNotAnInterruption() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 60, plugged: true), preferences: .default, now: now)
        let events = detector.update(
            state(status: "NOCHARGING", percent: 60, plugged: false),
            preferences: .default,
            now: now
        )
        #expect(events.isEmpty)
    }

    /// Stopping while still plugged in, however, is worth knowing about.
    @Test func stoppingWhileStillPluggedInIsAnInterruption() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 60, plugged: true), preferences: .default, now: now)
        let events = detector.update(
            state(status: "NOCHARGING", percent: 60, plugged: true),
            preferences: .default,
            now: now
        )
        #expect(events == [.interrupted(status: .notCharging, percent: 60)])
    }

    @Test func firesThresholdOnceWhenCrossed() {
        var preferences = NotificationPreferences.default
        preferences.socThreshold = 80

        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 70, plugged: true), preferences: preferences, now: now)
        #expect(
            detector.update(state(status: "CHARGINGACTIVE", percent: 79, plugged: true), preferences: preferences, now: now)
                .isEmpty
        )
        #expect(
            detector.update(state(status: "CHARGINGACTIVE", percent: 81, plugged: true), preferences: preferences, now: now)
                == [.thresholdReached(percent: 81, threshold: 80)]
        )
        // Crossing again in the same session must stay quiet.
        #expect(
            detector.update(state(status: "CHARGINGACTIVE", percent: 85, plugged: true), preferences: preferences, now: now)
                .isEmpty
        )
    }

    /// The most valuable warning: cable in, nothing happening.
    @Test func warnsWhenPluggedInButNothingHappens() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: false), preferences: .default, now: now)
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: .default, now: now)

        // Still inside the grace period.
        #expect(
            detector.update(
                state(status: "NOCHARGING", percent: 40, plugged: true),
                preferences: .default,
                now: now.addingTimeInterval(60)
            ).isEmpty
        )

        let events = detector.update(
            state(status: "NOCHARGING", percent: 40, plugged: true),
            preferences: .default,
            now: now.addingTimeInterval(6 * 60)
        )
        #expect(events == [.pluggedInButIdle(minutes: 5)])
    }

    /// A car sitting on a finished charge is plugged in and idle, but that is normal.
    @Test func doesNotWarnAfterAChargeCompleted() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: false), preferences: .default, now: now)
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: .default, now: now)
        _ = detector.update(state(status: "CHARGINGACTIVE", percent: 41, plugged: true), preferences: .default, now: now)
        _ = detector.update(state(status: "CHARGINGENDED", percent: 80, plugged: true), preferences: .default, now: now)

        let later = detector.update(
            state(status: "CHARGINGENDED", percent: 80, plugged: true),
            preferences: .default,
            now: now.addingTimeInterval(60 * 60)
        )
        #expect(later.isEmpty)
    }

    @Test func warnsAgainForANewSessionAfterReplugging() {
        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: .default, now: now)
        _ = detector.update(
            state(status: "NOCHARGING", percent: 40, plugged: true),
            preferences: .default,
            now: now.addingTimeInterval(6 * 60)
        )
        // Unplug, then plug in again: the grace period restarts.
        _ = detector.update(
            state(status: "NOCHARGING", percent: 40, plugged: false),
            preferences: .default,
            now: now.addingTimeInterval(7 * 60)
        )
        _ = detector.update(
            state(status: "NOCHARGING", percent: 40, plugged: true),
            preferences: .default,
            now: now.addingTimeInterval(8 * 60)
        )
        let events = detector.update(
            state(status: "NOCHARGING", percent: 40, plugged: true),
            preferences: .default,
            now: now.addingTimeInterval(14 * 60)
        )
        #expect(events == [.pluggedInButIdle(minutes: 5)])
    }

    @Test func respectsDisabledPreferences() {
        var preferences = NotificationPreferences.default
        preferences.chargingStarted = false

        var detector = ChargingEventDetector()
        _ = detector.update(state(status: "NOCHARGING", percent: 40, plugged: true), preferences: preferences, now: now)
        #expect(
            detector.update(state(status: "CHARGINGACTIVE", percent: 40, plugged: true), preferences: preferences, now: now)
                .isEmpty
        )
    }

    @Test func allDisabledMeansNoPermissionPrompt() {
        let preferences = NotificationPreferences(
            chargingStarted: false,
            chargingFinished: false,
            chargingInterrupted: false,
            pluggedInButIdle: false,
            socThreshold: nil,
            leftOpen: false,
            alarm: false,
            tyrePressure: false,
            preconditioningFinished: false
        )
        #expect(!preferences.wantsAnything)
        #expect(NotificationPreferences.default.wantsAnything)
    }
}

@Suite("Notification wording")
struct ChargingEventPresentationTests {
    @Test func limitAndFullReadDifferently() {
        #expect(ChargingEvent.finished(percent: 80, reachedLimit: true).title == "Charge limit reached")
        #expect(ChargingEvent.finished(percent: 100, reachedLimit: false).title == "Charge complete")
    }

    @Test func problemsAreFlaggedForAStrongerAlert() {
        #expect(ChargingEvent.interrupted(status: .error, percent: 50).isProblem)
        #expect(ChargingEvent.pluggedInButIdle(minutes: 5).isProblem)
        #expect(!ChargingEvent.started(percent: 50).isProblem)
        #expect(!ChargingEvent.finished(percent: 80, reachedLimit: true).isProblem)
    }

    @Test func bodyCopesWithAnUnknownPercentage() {
        #expect(!ChargingEvent.started(percent: nil).body.isEmpty)
        #expect(!ChargingEvent.finished(percent: nil, reachedLimit: true).body.isEmpty)
    }
}

@Suite("Cached vehicle state")
struct VehicleStateStoreTests {
    /// The cache is what makes a launch cost zero API calls, so values must survive a
    /// round trip intact — including units and timestamps.
    @Test func roundTripsValuesUnitsAndTimestamps() throws {
        let original: [String: TelematicValue] = [
            Descriptor.socDisplayed: TelematicValue(
                raw: .number(66),
                unit: "%",
                timestamp: Date(timeIntervalSince1970: 1_788_782_400)
            ),
            Descriptor.chargingStatus: TelematicValue(raw: .string("NOCHARGING")),
            Descriptor.plugged: TelematicValue(raw: .bool(false)),
        ]

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: TelematicValue].self, from: encoded)

        #expect(decoded[Descriptor.socDisplayed]?.doubleValue == 66)
        #expect(decoded[Descriptor.socDisplayed]?.unit == "%")
        #expect(decoded[Descriptor.socDisplayed]?.timestamp == Date(timeIntervalSince1970: 1_788_782_400))
        #expect(decoded[Descriptor.chargingStatus]?.stringValue == "NOCHARGING")
        #expect(decoded[Descriptor.plugged]?.boolValue == false)
    }
}

@Suite("Config forward compatibility")
struct ConfigCompatibilityTests {
    /// Regression: adding a preference must not orphan an existing install.
    ///
    /// `Config.load()` falls back to an empty config on *any* decode error, so a
    /// preferences struct that rejects older JSON silently discards the client ID and
    /// VIN with it — the app appears signed out.
    @Test func decodesAConfigWrittenBeforeNewPreferencesExisted() throws {
        let legacy = """
        {
          "clientID": "abc-123",
          "vin": "WBYTESTVIN1234567",
          "vehicleName": "BMW i4 eDrive35",
          "notifications": {
            "chargingStarted": true,
            "chargingFinished": true,
            "chargingInterrupted": true,
            "pluggedInButIdle": true,
            "idleGraceMinutes": 5
          }
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))

        #expect(config.clientID == "abc-123")
        #expect(config.vin == "WBYTESTVIN1234567")
        // Fields the old file never had take their defaults.
        #expect(config.notificationPreferences.leftOpen)
        #expect(config.notificationPreferences.tyreMarginBar == 0.3)
        #expect(config.notificationPreferences.idleGraceMinutes == 5)
    }

    /// A config from before notifications existed at all.
    @Test func decodesAConfigWithNoNotificationsKey() throws {
        let config = try JSONDecoder().decode(
            Config.self,
            from: Data(#"{"clientID":"abc","vin":"V"}"#.utf8)
        )
        #expect(config.clientID == "abc")
        #expect(config.notificationPreferences == .default)
    }

    @Test func roundTripsCurrentPreferences() throws {
        var preferences = NotificationPreferences.default
        preferences.socThreshold = 80
        preferences.tyreMarginBar = 0.5

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: data)
        #expect(decoded == preferences)
    }
}
