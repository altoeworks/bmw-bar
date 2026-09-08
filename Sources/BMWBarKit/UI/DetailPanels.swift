import MapKit
import SwiftUI

/// Routes to the panel behind a tile.
struct DetailPanel: View {
    let detail: DashboardDetail
    let model: AppModel

    var body: some View {
        switch detail {
        case .charging: ChargingDetail(vehicle: model.vehicle, sessions: model.chargingSessions)
        case .security: SecurityDetail(vehicle: model.vehicle)
        case .body: BodyDetail(vehicle: model.vehicle)
        case .tyres: TyresDetail(vehicle: model.vehicle, marginBar: model.notifications.tyreMarginBar)
        case .location: LocationDetail(vehicle: model.vehicle)
        case .climate: ClimateDetail(vehicle: model.vehicle)
        case .trip: TripDetail(vehicle: model.vehicle)
        }
    }
}

// MARK: - Body

/// Every door, window and lid, grouped.
///
/// Open and locked are shown as separate columns because BMW reports them for different
/// points: only the boot has both.
struct BodyDetail: View {
    let vehicle: VehicleState

    var body: some View {
        let points = vehicle.bodyOpenings
        let groups = ["Doors", "Windows", "Other"]

        VStack(alignment: .leading, spacing: 12) {
            if points.allSatisfy({ $0.opening == nil && $0.isLocked == nil }) {
                DetailEmpty()
            } else {
                ForEach(groups, id: \.self) { group in
                    let inGroup = points.filter { $0.group == group }
                    if !inGroup.isEmpty {
                        DetailSection(title: group, footnote: footnote(for: group)) {
                            ForEach(inGroup) { point in
                                DetailRow(
                                    label: point.name,
                                    value: point.openingText,
                                    tone: tone(for: point),
                                    badge: point.lockText,
                                    badgeTone: point.isLocked == true ? .secondary : .orange
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func tone(for point: BodyOpening) -> Color {
        switch point.opening {
        case .open: return .orange
        // A window left ajar is the case worth catching, so it is not styled as closed.
        case .ajar: return .orange
        case .closed: return .primary
        case nil: return .secondary
        }
    }

    private func footnote(for group: String) -> String? {
        switch group {
        case "Doors":
            // Stated plainly so the absence doesn't read as a bug in the app.
            return "BMW publishes no per-door lock state — only the boot and charge flap "
                + "report locking. The alarm is the closest thing to a whole-car lock."
        case "Windows":
            return "\"Ajar\" is BMW's INTERMEDIATE position — not fully closed."
        default:
            return nil
        }
    }
}

// MARK: - Security

struct SecurityDetail: View {
    let vehicle: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection(
                title: "Alarm",
                footnote: "BMW arms the alarm when the car is locked, so an armed alarm is "
                    + "good evidence the doors are locked — but it is evidence, not a lock reading."
            ) {
                DetailRow(
                    label: "Arm state",
                    value: vehicle.alarmArmState?.displayName,
                    tone: vehicle.alarmArmState?.isArmed == false ? .orange : .primary
                )
                DetailRow(
                    label: "Triggered",
                    value: vehicle.isAlarmTriggered.map { $0 ? "Yes" : "No" },
                    tone: vehicle.isAlarmTriggered == true ? .red : .primary
                )
            }

            let lockable = vehicle.lockableThings
            if !lockable.isEmpty {
                DetailSection(title: "Locks reported") {
                    ForEach(lockable) { point in
                        DetailRow(
                            label: point.name,
                            value: point.lockText,
                            tone: point.isLocked == true ? .primary : .orange
                        )
                    }
                }
            }

            let open = vehicle.openThings
            DetailSection(title: "Openings") {
                DetailRow(
                    label: open.isEmpty ? "Everything closed" : "Open right now",
                    value: open.isEmpty ? "Yes" : "\(open.count)",
                    tone: open.isEmpty ? .primary : .orange
                )
            }
        }
    }
}

// MARK: - Tyres

struct TyresDetail: View {
    let vehicle: VehicleState
    var marginBar: Double

    var body: some View {
        let tyres = vehicle.tyres
        VStack(alignment: .leading, spacing: 12) {
            if tyres.isEmpty {
                DetailEmpty()
            } else {
                DetailSection(
                    title: "Pressure vs target",
                    footnote: "BMW streams kPa; shown in bar. Flagged when more than "
                        + String(format: "%.1f", marginBar) + " bar below target."
                ) {
                    ForEach(tyres, id: \.position) { tyre in
                        DetailRow(
                            label: tyre.position,
                            value: pressureText(tyre),
                            tone: isLow(tyre) ? .orange : .primary,
                            badge: deficitBadge(tyre),
                            badgeTone: .orange
                        )
                    }
                }

                let temps = tyres.filter { $0.temperatureCelsius != nil }
                if !temps.isEmpty {
                    DetailSection(title: "Temperature") {
                        ForEach(temps, id: \.position) { tyre in
                            DetailRow(
                                label: tyre.position,
                                value: tyre.temperatureCelsius.map { String(format: "%.0f °C", $0) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func isLow(_ tyre: TyreReading) -> Bool { (tyre.deficitBar ?? 0) > marginBar }

    private func pressureText(_ tyre: TyreReading) -> String? {
        guard let pressure = tyre.pressureBar else { return nil }
        guard let target = tyre.targetBar else { return String(format: "%.1f bar", pressure) }
        return String(format: "%.1f / %.1f bar", pressure, target)
    }

    private func deficitBadge(_ tyre: TyreReading) -> String? {
        guard let deficit = tyre.deficitBar, deficit > marginBar else { return nil }
        return String(format: "−%.1f", deficit)
    }
}

// MARK: - Charging

struct ChargingDetail: View {
    let vehicle: VehicleState
    let sessions: [ChargingSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection(title: "Now") {
                DetailRow(label: "Status", value: vehicle.chargingStatus?.displayName)
                DetailRow(
                    label: "Plug",
                    value: vehicle.isPluggedIn.map { $0 ? "Connected" : "Unplugged" }
                )
                DetailRow(label: "Type", value: vehicle.chargingPlugType)
                DetailRow(
                    label: "Power",
                    value: vehicle.chargingPowerKW.map { String(format: "%.1f kW", $0) }
                )
                DetailRow(label: "Time remaining", value: remaining)
            }

            DetailSection(
                title: "Supply",
                footnote: "AC voltage, current and phase count only populate while a "
                    + "charge is actually running."
            ) {
                DetailRow(label: "Voltage", value: unit(Descriptor.chargingACVoltage, "V"))
                DetailRow(label: "Current", value: unit(Descriptor.chargingACAmpere, "A"))
                DetailRow(label: "Phases", value: vehicle[Descriptor.chargingPhases]?.stringValue)
                DetailRow(
                    label: "Current limit",
                    value: vehicle.acCurrentLimitAmps.map { String(format: "%.0f A", $0) }
                )
                DetailRow(
                    label: "Releases when done",
                    value: vehicle.plugUnlocksAutomatically.map { $0 ? "Yes" : "No" }
                )
            }

            DetailSection(
                title: "Battery",
                footnote: vehicle.isChargeEstimated()
                    ? "BMW publishes on events, not on a clock, so nothing arrives while a "
                        + "charge simply progresses. The estimate extrapolates from the last "
                        + "reading using power and pack capacity, and is replaced the moment "
                        + "the car reports again."
                    : nil
            ) {
                DetailRow(
                    label: "Charge",
                    value: vehicle.chargePercent.map { "\(Int($0.rounded()))%" },
                    badge: vehicle.chargeReportedAt.map(Self.age(of:)) ?? nil
                )

                DetailRow(
                    label: "Limit",
                    value: vehicle.chargeLimitPercent.map { "\(Int($0.rounded()))%" }
                )
                DetailRow(label: "Energy to full", value: unit(Descriptor.energyToFull, "kWh"))
                DetailRow(label: "Usable capacity", value: unit(Descriptor.maxEnergy, "kWh"))
            }

            if !sessions.isEmpty {
                DetailSection(
                    title: "Recent sessions",
                    footnote: "Recorded locally from the stream — no API calls. Energy is "
                        + "integrated from the power curve, so it is approximate."
                ) {
                    ForEach(sessions.prefix(5)) { session in
                        DetailRow(
                            label: session.startedAt.formatted(
                                .dateTime.day().month(.abbreviated).hour().minute()
                            ),
                            value: summary(session),
                            tone: session.isInProgress
                                ? VehicleMood.Tone.charging.color
                                : (session.completedNormally ? .primary : .orange),
                            badge: session.isInProgress ? "in progress" : nil,
                            badgeTone: VehicleMood.Tone.charging.color
                        )
                    }
                }
            }
        }
    }

    /// How stale a reading is, for the badge beside it.
    static func age(of date: Date) -> String? {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        guard minutes >= 1 else { return nil }
        return minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }

    private var remaining: String? {
        guard let minutes = vehicle.chargingMinutesRemaining, minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func unit(_ descriptor: String, _ suffix: String) -> String? {
        vehicle[descriptor]?.doubleValue.map { value in
            value == value.rounded()
                ? "\(Int(value)) \(suffix)"
                : String(format: "%.1f \(suffix)", value)
        }
    }

    private func summary(_ session: ChargingSession) -> String {
        var parts: [String] = []
        if let gained = session.socGained, gained > 0 { parts.append("+\(Int(gained.rounded()))%") }
        if let energy = session.energyKWh { parts.append(String(format: "~%.1f kWh", energy)) }
        let minutes = Int(session.duration / 60)
        parts.append(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Climate

struct ClimateDetail: View {
    let vehicle: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection(
                title: "Preconditioning",
                footnote: "BMW streams only a target temperature — never an ambient or "
                    + "cabin reading — so heating and cooling cannot be told apart."
            ) {
                DetailRow(
                    label: "State",
                    value: vehicle.preconditioning.map { $0.isActive ? "Running" : "Off" },
                    tone: vehicle.isPreconditioning ? VehicleMood.Tone.preconditioning.color : .primary
                )
                DetailRow(label: "Manual", value: raw(Descriptor.preconditioningManual))
                DetailRow(label: "Automatic", value: raw(Descriptor.preconditioningAuto))
                DetailRow(
                    label: "Target",
                    value: vehicle.targetTemperatureCelsius.map { String(format: "%.0f °C", $0) }
                )
            }
        }
    }

    private func raw(_ descriptor: String) -> String? {
        vehicle[descriptor]?.stringValue?.capitalized
    }
}

// MARK: - Location

struct LocationDetail: View {
    let vehicle: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let location = vehicle.location {
                let coordinate = CLLocationCoordinate2D(
                    latitude: location.latitude,
                    longitude: location.longitude
                )
                // Pannable here, unlike the tile's static thumbnail.
                Map(
                    initialPosition: .region(
                        MKCoordinateRegion(
                            center: coordinate,
                            latitudinalMeters: 400,
                            longitudinalMeters: 400
                        )
                    )
                ) {
                    Marker("Car", systemImage: "car.fill", coordinate: coordinate)
                        .tint(Color.accentColor)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                DetailSection(title: "Position") {
                    DetailRow(label: "Latitude", value: String(format: "%.5f", location.latitude))
                    DetailRow(label: "Longitude", value: String(format: "%.5f", location.longitude))
                    DetailRow(
                        label: "Heading",
                        value: location.heading.map { "\(Int($0.rounded()))° \(compass($0))" }
                    )
                    DetailRow(
                        label: "Altitude",
                        value: vehicle[Descriptor.altitude]?.doubleValue
                            .map { "\(Int($0.rounded())) m" }
                    )
                }

                Link(destination: mapsURL(location)) {
                    Label("Open in Maps", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
            } else {
                DetailEmpty()
            }
        }
    }

    private func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return points[index]
    }

    private func mapsURL(_ location: VehicleLocation) -> URL {
        URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Car")!
    }
}

// MARK: - Trip

struct TripDetail: View {
    let vehicle: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection(
                title: "Last trip",
                footnote: "Trip fields only refresh after the car finishes a drive."
            ) {
                DetailRow(
                    label: "Used",
                    value: vehicle.lastTripConsumptionKWh.map { String(format: "%.1f kWh", $0) }
                )
                DetailRow(
                    label: "Recuperated",
                    value: vehicle.lastTripRecuperationKWh.map { String(format: "%.1f kWh", $0) }
                )
                DetailRow(
                    label: "Electric share",
                    value: vehicle.lastTripElectricPercent.map { "\(Int($0.rounded()))%" }
                )
                DetailRow(
                    label: "Odometer after",
                    value: vehicle.lastTripDistanceKm.map { "\(Int($0.rounded())) km" }
                )
            }

            DetailSection(title: "Overall") {
                DetailRow(
                    label: "Average",
                    value: vehicle[Descriptor.avgConsumption]?.doubleValue
                        .map { String(format: "%.1f kWh / 100 km", $0) }
                )
                DetailRow(
                    label: "Odometer",
                    value: vehicle.odometerKm.map {
                        $0.formatted(.number.precision(.fractionLength(0))) + " km"
                    }
                )
                DetailRow(
                    label: "Range now",
                    value: vehicle.electricRangeKm.map { "\(Int($0.rounded())) km" }
                )
            }
        }
    }
}
