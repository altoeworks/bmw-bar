import Foundation
import Observation

/// The current picture of the car, assembled from a REST baseline plus streamed deltas.
///
/// The stream sends only descriptors that changed, so state is a dictionary that gets
/// merged into rather than replaced. Merges are timestamp-aware: an out-of-order
/// message must not overwrite a newer reading.
@Observable
public final class VehicleState {
    public private(set) var values: [String: TelematicValue] = [:]
    /// When we last heard anything at all from the car.
    public private(set) var lastUpdate: Date?

    public var vin: String?
    public var vehicleName: String?
    public var batteryCapacityKWh: Double?

    public init() {}

    /// Merges a delta, keeping the newer reading per descriptor.
    public func merge(_ delta: [String: TelematicValue], receivedAt: Date = Date()) {
        for (key, incoming) in delta {
            if let existing = values[key],
               let existingTime = existing.timestamp,
               let incomingTime = incoming.timestamp,
               incomingTime < existingTime {
                continue  // stale message, keep what we have
            }
            values[key] = incoming
        }
        if !delta.isEmpty { lastUpdate = receivedAt }
    }

    public func replaceAll(with snapshot: [String: TelematicValue], receivedAt: Date = Date()) {
        values = snapshot
        lastUpdate = snapshot.isEmpty ? lastUpdate : receivedAt
    }

    public subscript(descriptor: String) -> TelematicValue? { values[descriptor] }

    // MARK: - Typed accessors

    /// Charge level in percent. Prefers the value the car displays on its own cluster,
    /// falling back to the battery-management header.
    public var chargePercent: Double? {
        self[Descriptor.socDisplayed]?.doubleValue
            ?? self[Descriptor.socHeader]?.doubleValue
    }

    /// The charge limit configured in the car. Read-only — BMW exposes no setter.
    public var chargeLimitPercent: Double? {
        self[Descriptor.socTarget]?.doubleValue
    }

    /// When the car actually measured the charge level, by its own clock.
    public var chargeReportedAt: Date? {
        self[Descriptor.socDisplayed]?.timestamp ?? self[Descriptor.socHeader]?.timestamp
    }

    /// Usable pack capacity in kWh, needed to turn kW into %/hour.
    public var usableCapacityKWh: Double? {
        self[Descriptor.maxEnergy]?.doubleValue ?? batteryCapacityKWh
    }

    /// Charge extrapolated forward from the last reading, for the gaps between reports.
    ///
    /// **Why this exists:** BMW CarData is event-driven. The car publishes when
    /// something *happens* — locked, plugged in, charge started — but a charge level
    /// quietly climbing is not an event, so nothing is sent. Observed on a real i4:
    /// 22 minutes of active charging with no message at all, then a lock event released
    /// a burst showing the charge had gone 64% → 69% the whole time. The MyBMW app
    /// looks live only because opening it wakes the car and queries it.
    ///
    /// So the number is estimated between reports: energy in = power × time, converted
    /// to percent via the pack's usable capacity. Against that real 22-minute gap this
    /// predicted 70.0% where the car later said 69% — about a point high, since the
    /// figure ignores charging losses and BMW reports whole percents. Never presented
    /// as a reading, and any real reading immediately replaces it.
    public func predictedChargePercent(asOf now: Date = Date()) -> Double? {
        guard isCharging,
              let reported = chargePercent,
              let reportedAt = chargeReportedAt,
              let power = chargingPowerKW, power > 0,
              let capacity = usableCapacityKWh, capacity > 0
        else { return nil }

        let hours = now.timeIntervalSince(reportedAt) / 3600
        guard hours > 0 else { return nil }

        let gained = power * hours / capacity * 100
        // Charging stops at the limit, so the estimate must not sail past it.
        let ceiling = chargeLimitPercent ?? 100
        return min(reported + gained, ceiling)
    }

    /// The charge to show: the estimate while charging, the reading otherwise.
    public func displayChargePercent(asOf now: Date = Date()) -> Double? {
        predictedChargePercent(asOf: now) ?? chargePercent
    }

    /// Whether `displayChargePercent` is an extrapolation rather than a reading, so the
    /// UI can say so instead of implying precision it doesn't have.
    public func isChargeEstimated(asOf now: Date = Date()) -> Bool {
        guard let predicted = predictedChargePercent(asOf: now), let reported = chargePercent
        else { return false }
        // Below a whole percent of drift it is still effectively the reported number.
        return predicted - reported >= 1
    }

    /// The AC current limit selected in the car, in amps. Also read-only.
    public var acCurrentLimitAmps: Double? {
        self[Descriptor.acLimitSelected]?.doubleValue
    }

    /// The plug type in use, in plain words. `nil` when nothing is connected — BMW
    /// reports NOCHARGING rather than omitting the field.
    ///
    /// BMW's catalogue documents only `AC_TYPE1PLUG`, `AC_TYPE2PLUG` and `NOCHARGING`,
    /// but a real i4 streams `AC_TYP2COMBO` (a CCS Combo 2 inlet charging on AC), so
    /// the documented range cannot be treated as exhaustive. Unrecognised values are
    /// tidied rather than dropped, and never blindly `.capitalized` — that turned
    /// `AC_TYP2COMBO` into the nonsense "Ac Typ2Combo".
    public var chargingPlugType: String? {
        guard let raw = self[Descriptor.chargingMethod]?.stringValue?.uppercased() else {
            return nil
        }
        switch raw {
        case "NOCHARGING", "INVALID", "-NA-", "": return nil
        case "AC_TYPE1PLUG", "AC_TYP1PLUG": return "Type 1"
        case "AC_TYPE2PLUG", "AC_TYP2PLUG": return "Type 2"
        case "AC_TYPE2COMBO", "AC_TYP2COMBO": return "Type 2 Combo"
        case "DC_TYPE2COMBO", "DC_TYP2COMBO", "DC_CCS": return "CCS"
        default: return Self.tidyPlugName(raw)
        }
    }

    /// Best-effort readable name for a plug value BMW has not documented.
    static func tidyPlugName(_ raw: String) -> String {
        let body = raw
            .replacingOccurrences(of: "AC_", with: "")
            .replacingOccurrences(of: "DC_", with: "")
            .replacingOccurrences(of: "PLUG", with: "")
            .replacingOccurrences(of: "_", with: " ")
        // TYP2 / TYPE2 -> "Type 2"; leaves acronyms like CCS alone.
        let spaced = body
            .replacingOccurrences(of: "TYPE", with: "TYP")
            .replacingOccurrences(of: "TYP", with: "Type ")
            .replacingOccurrences(of: "COMBO", with: " Combo")
        return spaced
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether the charging plug releases itself when charging finishes. A setting the
    /// car holds, not something happening now.
    public var plugUnlocksAutomatically: Bool? {
        self[Descriptor.plugAutoUnlock]?.boolValue
    }

    /// Charging state, from whichever of BMW's two status descriptors actually says
    /// something — they use different vocabularies and either can read UNKNOWN.
    public var chargingStatus: ChargingStatus? {
        let candidates = [Descriptor.chargingStatus, Descriptor.chargingHVStatus]
            .compactMap { self[$0]?.stringValue }
            .map(ChargingStatus.init(raw:))
        return candidates.first(where: \.isInformative) ?? candidates.first
    }

    public var isCharging: Bool { chargingStatus?.isActivelyCharging ?? false }

    /// Charging power in kW. BMW's catalogue declares this descriptor in **watts**,
    /// but the unit field is not always populated, so a large bare number is also
    /// treated as watts.
    public var chargingPowerKW: Double? {
        guard let value = self[Descriptor.chargingPower],
              let power = value.doubleValue else { return nil }
        switch value.unit?.lowercased() {
        case "w": return power / 1000
        case "kw": return power
        default: return power > 1000 ? power / 1000 : power
        }
    }

    /// Minutes until the charge target is reached. BMW caps `timeRemaining` at 200
    /// minutes, so `timeToFullyCharged` covers longer sessions.
    public var chargingMinutesRemaining: Int? {
        self[Descriptor.chargingTimeRemaining]?.intValue
            ?? self[Descriptor.chargingTimeToFull]?.intValue
    }

    /// Whether a cable is connected. The port descriptor reports
    /// CONNECTED / DISCONNECTED / INVALID / -NA-, so anything but CONNECTED or
    /// DISCONNECTED is treated as unknown rather than guessed at.
    public var isPluggedIn: Bool? {
        if let plugged = self[Descriptor.plugged]?.boolValue { return plugged }
        switch self[Descriptor.chargingPortStatus]?.stringValue?.uppercased() {
        case "CONNECTED": return true
        case "DISCONNECTED": return false
        default: return nil
        }
    }

    /// Remaining range in km, from whichever of the two range descriptors reported
    /// most recently.
    ///
    /// Freshness, not preference: the i4 streams `lastRemainingRange` but never
    /// `kombiRemainingElectricRange`, so a fixed preference would pin the panel to a
    /// stale value from a one-off REST snapshot forever.
    public var electricRangeKm: Double? {
        let candidates = [Descriptor.electricRange, Descriptor.lastRemainingRange]
            .compactMap { self[$0] }
            .filter { $0.doubleValue != nil }
        return candidates
            .max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }?
            .doubleValue
    }

    public var odometerKm: Double? {
        self[Descriptor.mileage]?.doubleValue
    }

    /// Newest timestamp the car itself put on any value — distinct from `lastUpdate`,
    /// which is when the message reached us.
    public var newestReadingTimestamp: Date? {
        values.values.compactMap(\.timestamp).max()
    }
}

// MARK: - Openings, security, tyres, location, climate

/// How open a window is. BMW reports CLOSED / INTERMEDIATE / OPEN / INVALID, and the
/// intermediate position matters — a window left ajar is exactly what you want warning
/// about.
public enum OpeningState: Equatable, Sendable {
    case closed
    case ajar
    case open

    public init?(raw: String) {
        switch raw.uppercased() {
        case "CLOSED": self = .closed
        case "INTERMEDIATE": self = .ajar
        case "OPEN": self = .open
        default: return nil  // INVALID / -NA- are unknown, not "closed"
        }
    }

    public var isOpen: Bool { self != .closed }
}

/// One point on the car that can be open, locked, or both.
///
/// **Open and locked are separate facts, and BMW reports them for different points.**
/// Of 245 catalogued descriptors exactly two concern locking — `body.trunk.isLocked`
/// and `body.flap.isLocked` — so the boot is the only place both are known, the charge
/// flap reports only its lock, and doors and windows report only whether they are open.
/// `nil` means BMW publishes nothing for that combination, which the UI states plainly
/// rather than dressing up as "closed" or "unlocked".
public struct BodyOpening: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case door
        case window
        case boot
        case bonnet
        case chargeFlap
    }

    /// The descriptor id, which is stable and unique per point.
    public let id: String
    /// Short name within its group, e.g. "Front left".
    public let name: String
    public let group: String
    public let kind: Kind
    /// Windows distinguish a third state; everything else is only open or closed.
    public let opening: OpeningState?
    public let isLocked: Bool?

    public var isOpen: Bool? { opening?.isOpen }

    /// What to show for this point's state, in words.
    public var openingText: String {
        switch opening {
        case .closed: return "Closed"
        case .ajar: return "Ajar"
        case .open: return "Open"
        case nil: return "—"
        }
    }

    public var lockText: String? {
        isLocked.map { $0 ? "Locked" : "Unlocked" }
    }
}

/// BMW arms the alarm when the car is locked, so this is the closest thing to a lock
/// state the catalogue offers — there is no central-locking descriptor.
public enum AlarmArmState: Equatable, Sendable {
    case unarmed
    case doorsOnly
    case doorsAndInterior
    case unknown(String)

    public init(raw: String) {
        switch raw.uppercased() {
        case "UNARMED": self = .unarmed
        case "DOORSONLY", "DOORS_ONLY": self = .doorsOnly
        case "DOORSTILTCABIN", "DOORS_TILT_CABIN": self = .doorsAndInterior
        default: self = .unknown(raw)
        }
    }

    public var isArmed: Bool { self == .doorsOnly || self == .doorsAndInterior }

    public var displayName: String {
        switch self {
        case .unarmed: return "Not armed"
        case .doorsOnly: return "Armed"
        case .doorsAndInterior: return "Armed + interior"
        case .unknown(let raw): return raw.capitalized
        }
    }
}

public struct TyreReading: Equatable, Sendable {
    public let position: String
    /// Bar. BMW streams kPa.
    public let pressureBar: Double?
    public let targetBar: Double?
    public let temperatureCelsius: Double?

    /// How far below target, in bar. Negative means over-inflated.
    public var deficitBar: Double? {
        guard let pressureBar, let targetBar else { return nil }
        return targetBar - pressureBar
    }
}

public struct VehicleLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let heading: Double?
}

/// Preconditioning is either running or it isn't. BMW exposes no ambient or cabin
/// temperature, only a target, so heating and cooling cannot be distinguished.
public enum PreconditioningState: Equatable, Sendable {
    case off
    case active
    case unknown

    public init(raw: String) {
        switch raw.uppercased() {
        case "OFF", "REMOTE_OFF", "TEMP_OFF": self = .off
        case "UNKNOWN", "INVALID": self = .unknown
        default: self = .active  // ON_LEGACY, MANUAL_ON_CHARGE, AUTOMATIC_ON, REMOTE_ON_*
        }
    }

    public var isActive: Bool { self == .active }
}

extension VehicleState {
    /// kPa as streamed by BMW, converted to bar.
    static func barFromKilopascal(_ kPa: Double) -> Double { kPa / 100 }

    // MARK: Openings

    /// Every body point, in display order, whether or not the car has reported it.
    /// The single source of truth for the Body tile, its detail panel, and the
    /// "left open" notification.
    public var bodyOpenings: [BodyOpening] {
        let corners = ["Front left", "Front right", "Rear left", "Rear right"]

        var points = zip(Descriptor.doors, corners).map { id, name in
            BodyOpening(
                id: id,
                name: name,
                group: "Doors",
                kind: .door,
                // Doors report a plain boolean, so they can only be open or closed.
                opening: self[id]?.boolValue.map { $0 ? .open : .closed },
                isLocked: nil
            )
        }

        points += zip(Descriptor.windows, corners).map { id, name in
            BodyOpening(
                id: id,
                name: name,
                group: "Windows",
                kind: .window,
                opening: self[id]?.stringValue.flatMap(OpeningState.init(raw:)),
                isLocked: nil
            )
        }

        // The tailgate glass opens independently of the boot lid on some models.
        points.append(
            BodyOpening(
                id: Descriptor.rearWindowOpen,
                name: "Tailgate glass",
                group: "Windows",
                kind: .window,
                opening: openingState(Descriptor.rearWindowOpen),
                isLocked: nil
            )
        )

        points.append(
            BodyOpening(
                id: Descriptor.trunkOpen,
                name: "Boot",
                group: "Other",
                kind: .boot,
                opening: self[Descriptor.trunkOpen]?.boolValue.map { $0 ? .open : .closed },
                // The only point where BMW reports both facts.
                isLocked: self[Descriptor.trunkLocked]?.boolValue
            )
        )

        points.append(
            BodyOpening(
                id: Descriptor.hoodOpen,
                name: "Bonnet",
                group: "Other",
                kind: .bonnet,
                opening: self[Descriptor.hoodOpen]?.boolValue.map { $0 ? .open : .closed },
                isLocked: nil
            )
        )

        points.append(
            BodyOpening(
                id: Descriptor.chargeFlapLocked,
                name: "Charge flap",
                group: "Other",
                kind: .chargeFlap,
                // No open/closed descriptor exists for the flap, only its lock.
                opening: nil,
                isLocked: self[Descriptor.chargeFlapLocked]?.boolValue
            )
        )

        return points
    }

    /// Handles descriptors BMW sends as either a boolean or a CLOSED/OPEN string.
    private func openingState(_ descriptor: String) -> OpeningState? {
        guard let value = self[descriptor] else { return nil }
        if let flag = value.boolValue, value.stringValue.flatMap(OpeningState.init(raw:)) == nil {
            return flag ? .open : .closed
        }
        return value.stringValue.flatMap(OpeningState.init(raw:))
    }

    public var openDoors: [String] {
        bodyOpenings.filter { $0.kind == .door && $0.isOpen == true }
            .map { Descriptor.label(for: $0.id) }
    }

    public var openWindows: [String] {
        bodyOpenings.filter { $0.kind == .window && $0.isOpen == true }
            .map { Descriptor.label(for: $0.id) }
    }

    public var isTrunkOpen: Bool? { self[Descriptor.trunkOpen]?.boolValue }
    public var isHoodOpen: Bool? { self[Descriptor.hoodOpen]?.boolValue }

    /// Everything that could be left open, named. Empty means buttoned up; points the
    /// car never reported are not guessed at.
    public var openThings: [String] {
        bodyOpenings.filter { $0.isOpen == true }.map { Descriptor.label(for: $0.id) }
    }

    /// Points that report a lock state at all — the boot and the charge flap.
    public var lockableThings: [BodyOpening] {
        bodyOpenings.filter { $0.isLocked != nil }
    }

    /// Anything that reports a lock and is currently unlocked.
    public var unlockedThings: [BodyOpening] {
        bodyOpenings.filter { $0.isLocked == false }
    }

    /// True only when at least one opening actually reported, and all of them are shut.
    public var isAllClosed: Bool? {
        let reported = bodyOpenings.contains { $0.opening != nil }
        return reported ? openThings.isEmpty : nil
    }

    // MARK: Security

    public var alarmArmState: AlarmArmState? {
        self[Descriptor.alarmArmStatus]?.stringValue.map(AlarmArmState.init(raw:))
    }

    public var isAlarmTriggered: Bool? { self[Descriptor.alarmIsOn]?.boolValue }

    // MARK: Tyres

    public var tyres: [TyreReading] {
        let positions = ["Front left", "Front right", "Rear left", "Rear right"]
        return zip(0..<4, positions).compactMap { index, position in
            let pressure = self[Descriptor.tyrePressures[index]]?.doubleValue
            let target = self[Descriptor.tyreTargets[index]]?.doubleValue
            let temperature = self[Descriptor.tyreTemperatures[index]]?.doubleValue
            guard pressure != nil || target != nil || temperature != nil else { return nil }
            return TyreReading(
                position: position,
                pressureBar: pressure.map(Self.barFromKilopascal),
                targetBar: target.map(Self.barFromKilopascal),
                temperatureCelsius: temperature
            )
        }
    }

    /// Tyres more than `margin` bar below target.
    public func underinflatedTyres(margin: Double = 0.2) -> [TyreReading] {
        tyres.filter { ($0.deficitBar ?? 0) > margin }
    }

    // MARK: Location

    public var location: VehicleLocation? {
        guard let lat = self[Descriptor.latitude]?.doubleValue,
              let lon = self[Descriptor.longitude]?.doubleValue,
              // BMW sends 0,0 when it has no fix.
              !(lat == 0 && lon == 0)
        else { return nil }
        return VehicleLocation(
            latitude: lat,
            longitude: lon,
            heading: self[Descriptor.heading]?.doubleValue
        )
    }

    // MARK: Climate

    public var preconditioning: PreconditioningState? {
        let candidates = [
            Descriptor.preconditioningState,
            Descriptor.preconditioningManual,
            Descriptor.preconditioningAuto,
        ]
        .compactMap { self[$0]?.stringValue }
        .map(PreconditioningState.init(raw:))

        // Any source reporting activity wins; otherwise fall back to the first reading.
        return candidates.first(where: \.isActive) ?? candidates.first
    }

    public var isPreconditioning: Bool { preconditioning?.isActive ?? false }

    public var targetTemperatureCelsius: Double? {
        self[Descriptor.targetTemperature]?.doubleValue
    }

    // MARK: Last trip

    public var lastTripDistanceKm: Double? { self[Descriptor.tripEndDistance]?.doubleValue }
    public var lastTripConsumptionKWh: Double? { self[Descriptor.tripConsumption]?.doubleValue }
    public var lastTripRecuperationKWh: Double? { self[Descriptor.tripRecuperation]?.doubleValue }
    public var lastTripElectricPercent: Double? { self[Descriptor.tripElectricFraction]?.doubleValue }
}
