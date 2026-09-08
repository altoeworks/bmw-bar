import Foundation

/// Something worth telling the user about, derived from changes in `VehicleState`.
public enum ChargingEvent: Equatable, Sendable {
    case started(percent: Double?)
    /// Charging finished. `reachedLimit` distinguishes "stopped at your charge limit"
    /// from "battery is actually full".
    case finished(percent: Double?, reachedLimit: Bool)
    /// Charging stopped before finishing — paused, errored, or simply went quiet
    /// while still plugged in.
    case interrupted(status: ChargingStatus, percent: Double?)
    case thresholdReached(percent: Double, threshold: Int)
    /// Plugged in, but nothing happened. The classic "I came back to an empty car"
    /// case: a cable seated wrong, or a wallbox that never authorised.
    case pluggedInButIdle(minutes: Int)
    /// Something is open on a car that has been left alone.
    case leftOpen(what: [String])
    case alarmTriggered
    /// Tyres measurably below their target pressure.
    case tyrePressureLow(positions: [String])
    case preconditioningFinished
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var chargingStarted: Bool
    public var chargingFinished: Bool
    public var chargingInterrupted: Bool
    public var pluggedInButIdle: Bool
    /// Notify once per session when charge crosses this percentage. `nil` disables it.
    public var socThreshold: Int?
    /// How long a plugged-in car may sit idle before warning.
    public var idleGraceMinutes: Int
    public var leftOpen: Bool
    public var alarm: Bool
    public var tyrePressure: Bool
    public var preconditioningFinished: Bool
    /// How far below target a tyre must be, in bar, before it is worth mentioning.
    public var tyreMarginBar: Double

    public init(
        chargingStarted: Bool = true,
        chargingFinished: Bool = true,
        chargingInterrupted: Bool = true,
        pluggedInButIdle: Bool = true,
        socThreshold: Int? = nil,
        idleGraceMinutes: Int = 5,
        leftOpen: Bool = true,
        alarm: Bool = true,
        tyrePressure: Bool = true,
        preconditioningFinished: Bool = false,
        tyreMarginBar: Double = 0.3
    ) {
        self.chargingStarted = chargingStarted
        self.chargingFinished = chargingFinished
        self.chargingInterrupted = chargingInterrupted
        self.pluggedInButIdle = pluggedInButIdle
        self.socThreshold = socThreshold
        self.idleGraceMinutes = idleGraceMinutes
        self.leftOpen = leftOpen
        self.alarm = alarm
        self.tyrePressure = tyrePressure
        self.preconditioningFinished = preconditioningFinished
        self.tyreMarginBar = tyreMarginBar
    }

    public static let `default` = NotificationPreferences()

    /// Decoded tolerantly: every key falls back to its default when absent.
    ///
    /// Without this, adding a preference makes older `config.json` files fail to decode
    /// — and because `Config.load()` falls back to an empty config on any error, that
    /// silently discards the client ID and VIN too. Never let a new field orphan an
    /// existing install.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NotificationPreferences()

        func flag(_ key: CodingKeys, _ defaultValue: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) .flatMap { $0 } ?? defaultValue
        }

        chargingStarted = flag(.chargingStarted, fallback.chargingStarted)
        chargingFinished = flag(.chargingFinished, fallback.chargingFinished)
        chargingInterrupted = flag(.chargingInterrupted, fallback.chargingInterrupted)
        pluggedInButIdle = flag(.pluggedInButIdle, fallback.pluggedInButIdle)
        leftOpen = flag(.leftOpen, fallback.leftOpen)
        alarm = flag(.alarm, fallback.alarm)
        tyrePressure = flag(.tyrePressure, fallback.tyrePressure)
        preconditioningFinished = flag(.preconditioningFinished, fallback.preconditioningFinished)
        socThreshold = (try? container.decodeIfPresent(Int.self, forKey: .socThreshold)) ?? nil
        idleGraceMinutes = (try? container.decodeIfPresent(Int.self, forKey: .idleGraceMinutes))
            .flatMap { $0 } ?? fallback.idleGraceMinutes
        tyreMarginBar = (try? container.decodeIfPresent(Double.self, forKey: .tyreMarginBar))
            .flatMap { $0 } ?? fallback.tyreMarginBar
    }

    /// True when any notification is switched on, so the app only asks macOS for
    /// permission if it would actually use it.
    public var wantsAnything: Bool {
        chargingStarted || chargingFinished || chargingInterrupted
            || pluggedInButIdle || socThreshold != nil
            || leftOpen || alarm || tyrePressure || preconditioningFinished
    }
}

/// When to fall back to a REST snapshot because the stream has gone quiet.
///
/// CarData publishes on events, not on a clock, so a charge can progress for a long
/// time in silence — 22 minutes of silent charging has been observed on a real i4.
///
/// Polling is deliberately limited to **while the car is charging**. That is the only
/// time the number changes on its own, so it is the only time a fetch buys anything: a
/// parked car polled all day would spend the whole 50-call budget to learn it is still
/// parked. Confining it that way is what makes a much shorter interval affordable.
public struct PollingPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Minutes of stream silence *while charging* before a snapshot is fetched.
    public var chargingIdleMinutes: Int

    public init(enabled: Bool = true, chargingIdleMinutes: Int = 15) {
        self.enabled = enabled
        self.chargingIdleMinutes = chargingIdleMinutes
    }

    public static let `default` = PollingPreferences()

    /// What the setting costs while a charge is actually running, which is the only
    /// figure that means anything now polling is charging-only.
    public var callsPerHourWhileCharging: Int {
        chargingIdleMinutes > 0 ? max(1, 60 / chargingIdleMinutes) : 0
    }

    /// Rough cost of a typical charge, for showing the user the real trade-off.
    public func calls(forChargeLasting hours: Double) -> Int {
        Int((Double(callsPerHourWhileCharging) * hours).rounded())
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case chargingIdleMinutes
        /// Pre-charging-only key, still read so an existing config keeps its interval.
        case idleMinutes
    }

    /// Decoded tolerantly, so adding a field later cannot orphan an existing config.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PollingPreferences()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled))
            .flatMap { $0 } ?? fallback.enabled
        chargingIdleMinutes =
            (try? container.decodeIfPresent(Int.self, forKey: .chargingIdleMinutes))
                .flatMap { $0 }
            ?? (try? container.decodeIfPresent(Int.self, forKey: .idleMinutes)).flatMap { $0 }
            ?? fallback.chargingIdleMinutes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(chargingIdleMinutes, forKey: .chargingIdleMinutes)
    }
}

/// Turns a stream of vehicle states into discrete charging events.
///
/// Deliberately pure and synchronous so the tricky parts — not firing on the launch
/// baseline, not repeating on every sparse stream message, distinguishing "finished"
/// from "interrupted" — are testable without a running app or a real car.
public struct ChargingEventDetector {
    struct Snapshot: Equatable {
        var status: ChargingStatus?
        var percent: Double?
        var plugged: Bool?
        var openThings: [String]
        var alarmTriggered: Bool?
        var lowTyres: [String]
        var preconditioning: Bool

        init(_ state: VehicleState, tyreMarginBar: Double) {
            status = state.chargingStatus
            percent = state.chargePercent
            plugged = state.isPluggedIn
            openThings = state.openThings.sorted()
            alarmTriggered = state.isAlarmTriggered
            lowTyres = state.underinflatedTyres(margin: tyreMarginBar).map(\.position)
            preconditioning = state.isPreconditioning
        }
    }

    private var previous: Snapshot?
    private var pluggedSince: Date?
    /// Whether charging actually happened since the cable went in — an idle warning
    /// after a completed charge would be wrong.
    private var didChargeThisSession = false
    private var warnedIdle = false
    private var notifiedThreshold = false

    public init() {}

    /// Events since the last call, already filtered by `preferences`.
    ///
    /// The first call only establishes a baseline and returns nothing — otherwise
    /// every launch would announce a charge that started hours ago.
    public mutating func update(
        _ state: VehicleState,
        preferences: NotificationPreferences,
        now: Date = Date()
    ) -> [ChargingEvent] {
        let current = Snapshot(state, tyreMarginBar: preferences.tyreMarginBar)
        defer { previous = current }

        guard let previous else {
            if current.plugged == true { pluggedSince = now }
            didChargeThisSession = current.status?.isActivelyCharging ?? false
            return []
        }

        var events: [ChargingEvent] = []

        // A new cable connection resets everything that is "once per session".
        if previous.plugged != true, current.plugged == true {
            pluggedSince = now
            didChargeThisSession = false
            warnedIdle = false
            notifiedThreshold = false
        }
        if current.plugged == false {
            pluggedSince = nil
            didChargeThisSession = false
            warnedIdle = false
            notifiedThreshold = false
        }

        let wasCharging = previous.status?.isActivelyCharging ?? false
        let isCharging = current.status?.isActivelyCharging ?? false
        if isCharging { didChargeThisSession = true }

        if !wasCharging, isCharging {
            notifiedThreshold = false
            if preferences.chargingStarted {
                events.append(.started(percent: current.percent))
            }
        }

        if wasCharging, !isCharging {
            switch current.status {
            case .complete:
                if preferences.chargingFinished {
                    events.append(.finished(percent: current.percent, reachedLimit: false))
                }
            case .ended:
                // BMW reports CHARGINGENDED / FINISHED_NOT_FULL when it stops at the
                // configured charge limit rather than a full pack.
                if preferences.chargingFinished {
                    events.append(.finished(percent: current.percent, reachedLimit: true))
                }
            case .paused, .error:
                if preferences.chargingInterrupted {
                    events.append(
                        .interrupted(status: current.status ?? .error, percent: current.percent)
                    )
                }
            case .notCharging:
                // Ambiguous on its own: stopping while still plugged in is a genuine
                // interruption, but stopping because the cable came out is not.
                if current.plugged == true, preferences.chargingInterrupted {
                    events.append(.interrupted(status: .notCharging, percent: current.percent))
                }
            default:
                break
            }
        }

        if let threshold = preferences.socThreshold,
           !notifiedThreshold,
           let before = previous.percent,
           let after = current.percent,
           before < Double(threshold), after >= Double(threshold) {
            notifiedThreshold = true
            events.append(.thresholdReached(percent: after, threshold: threshold))
        }

        if preferences.pluggedInButIdle,
           !warnedIdle,
           !didChargeThisSession,
           current.plugged == true,
           !isCharging,
           current.status != .complete,
           current.status != .ended,
           let since = pluggedSince,
           now.timeIntervalSince(since) >= Double(preferences.idleGraceMinutes) * 60 {
            warnedIdle = true
            events.append(.pluggedInButIdle(minutes: preferences.idleGraceMinutes))
        }

        // Only fire when something *newly* opens, so a car parked with a window down
        // does not nag on every message.
        if preferences.leftOpen, current.openThings != previous.openThings,
           !current.openThings.isEmpty {
            events.append(.leftOpen(what: current.openThings))
        }

        if preferences.alarm, previous.alarmTriggered != true, current.alarmTriggered == true {
            events.append(.alarmTriggered)
        }

        if preferences.tyrePressure, current.lowTyres != previous.lowTyres,
           !current.lowTyres.isEmpty {
            events.append(.tyrePressureLow(positions: current.lowTyres))
        }

        if preferences.preconditioningFinished, previous.preconditioning, !current.preconditioning {
            events.append(.preconditioningFinished)
        }

        return events
    }
}

// MARK: - Presentation

extension ChargingEvent {
    public var title: String {
        switch self {
        case .started: return "Charging started"
        case .finished(_, let reachedLimit): return reachedLimit ? "Charge limit reached" : "Charge complete"
        case .interrupted: return "Charging stopped"
        case .thresholdReached(_, let threshold): return "Battery at \(threshold)%"
        case .pluggedInButIdle: return "Plugged in, but not charging"
        case .leftOpen: return "Car left open"
        case .alarmTriggered: return "Alarm triggered"
        case .tyrePressureLow: return "Tyre pressure low"
        case .preconditioningFinished: return "Preconditioning finished"
        }
    }

    public var body: String {
        switch self {
        case .started(let percent):
            return percent.map { "Now at \(Self.format($0))%." } ?? "The car has started charging."
        case .finished(let percent, let reachedLimit):
            let where_ = percent.map { " at \(Self.format($0))%" } ?? ""
            return reachedLimit
                ? "Charging stopped\(where_) — the car's charge limit."
                : "The battery is full\(where_)."
        case .interrupted(let status, let percent):
            let where_ = percent.map { " at \(Self.format($0))%" } ?? ""
            return "\(status.displayName)\(where_). The car is still plugged in."
        case .thresholdReached(let percent, _):
            return "Charge reached \(Self.format(percent))%."
        case .pluggedInButIdle(let minutes):
            return "No charging \(minutes) minutes after the cable went in. "
                + "Check the plug or the wallbox."
        case .leftOpen(let what):
            return what.joined(separator: ", ") + (what.count == 1 ? " is open." : " are open.")
        case .alarmTriggered:
            return "The car's anti-theft alarm went off."
        case .tyrePressureLow(let positions):
            return positions.joined(separator: ", ")
                + (positions.count == 1 ? " is below target." : " are below target.")
        case .preconditioningFinished:
            return "The cabin should be ready."
        }
    }

    /// Problems should stand out from routine progress updates.
    public var isProblem: Bool {
        switch self {
        case .interrupted, .pluggedInButIdle, .leftOpen, .alarmTriggered, .tyrePressureLow:
            return true
        case .started, .finished, .thresholdReached, .preconditioningFinished:
            return false
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
