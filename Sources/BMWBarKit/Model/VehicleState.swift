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

    /// The AC current limit selected in the car, in amps. Also read-only.
    public var acCurrentLimitAmps: Double? {
        self[Descriptor.acLimitSelected]?.doubleValue
    }

    /// The plug type in use, in plain words. `nil` when nothing is connected — BMW
    /// reports NOCHARGING rather than omitting the field.
    public var chargingPlugType: String? {
        guard let raw = self[Descriptor.chargingMethod]?.stringValue?.uppercased() else {
            return nil
        }
        switch raw {
        case "AC_TYPE1PLUG": return "AC Type 1"
        case "AC_TYPE2PLUG": return "AC Type 2"
        case "NOCHARGING", "INVALID", "-NA-": return nil
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
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

    public var openDoors: [String] {
        Descriptor.doors.filter { self[$0]?.boolValue == true }
            .map(Descriptor.label(for:))
    }

    public var openWindows: [String] {
        Descriptor.windows.filter {
            self[$0]?.stringValue.flatMap(OpeningState.init(raw:))?.isOpen == true
        }
        .map(Descriptor.label(for:))
    }

    public var isTrunkOpen: Bool? { self[Descriptor.trunkOpen]?.boolValue }
    public var isHoodOpen: Bool? { self[Descriptor.hoodOpen]?.boolValue }

    /// Everything that could be left open, named. Empty means buttoned up; `nil`
    /// entries simply never reported and are not guessed at.
    public var openThings: [String] {
        var open = openDoors + openWindows
        if isTrunkOpen == true { open.append(Descriptor.label(for: Descriptor.trunkOpen)) }
        if isHoodOpen == true { open.append(Descriptor.label(for: Descriptor.hoodOpen)) }
        if self[Descriptor.rearWindowOpen]?.stringValue.flatMap(OpeningState.init(raw:))?.isOpen == true {
            open.append(Descriptor.label(for: Descriptor.rearWindowOpen))
        }
        return open
    }

    /// True only when at least one opening actually reported, and all of them are shut.
    public var isAllClosed: Bool? {
        let reported = (Descriptor.doors + Descriptor.windows
            + [Descriptor.trunkOpen, Descriptor.hoodOpen]).contains { self[$0] != nil }
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
