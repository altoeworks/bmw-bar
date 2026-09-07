import MapKit
import SwiftUI

/// A dashboard cell. Every tile has the same chrome so the grid reads as one surface,
/// and every tile renders even when its data has never arrived — a stable layout is
/// what makes the panel scannable at a glance.
struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var padded = true
    @ViewBuilder let content: Content

    static var corner: CGFloat { 12 }
    static var height: CGFloat { 78 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, padded ? 0 : 10)
            .padding(.top, padded ? 0 : 9)

            content
            Spacer(minLength: 0)
        }
        .padding(padded ? 10 : 0)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }
}

/// The primary reading inside a tile.
struct TileValue: View {
    let text: String
    var tone: Color = .primary
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Specific tiles

struct PlugTile: View {
    let vehicle: VehicleState

    var body: some View {
        let plugged = vehicle.isPluggedIn
        Tile(title: "Plug", symbol: plugged == true ? "powerplug.fill" : "powerplug") {
            switch plugged {
            case .some(true):
                TileValue(text: "Connected", detail: vehicle.chargingPlugType)
            case .some(false):
                TileValue(text: "Unplugged", tone: .secondary)
            case nil:
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

/// Alarm state stands in for "locked": BMW exposes no central-locking descriptor, and
/// arms the alarm when you lock. The tile never claims to know the doors are locked.
struct SecurityTile: View {
    let vehicle: VehicleState

    var body: some View {
        let triggered = vehicle.isAlarmTriggered == true
        let armed = vehicle.alarmArmState
        Tile(
            title: "Alarm",
            symbol: triggered ? "bell.badge.fill" : (armed?.isArmed == true ? "shield.fill" : "shield"),
            tint: triggered ? .red : .secondary
        ) {
            if triggered {
                TileValue(text: "Triggered", tone: .red)
            } else if let armed {
                TileValue(
                    text: armed.isArmed ? "Armed" : "Not armed",
                    tone: armed.isArmed ? .primary : .orange
                )
            } else if vehicle.isAlarmTriggered != nil {
                TileValue(text: "Quiet", detail: "Arm state not sent")
            } else {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

struct BodyTile: View {
    let vehicle: VehicleState

    var body: some View {
        let open = vehicle.openThings
        Tile(
            title: "Body",
            symbol: open.isEmpty ? "car.side" : "car.side.rear.open",
            tint: open.isEmpty ? .secondary : .orange
        ) {
            switch vehicle.isAllClosed {
            case .some(true):
                TileValue(text: "All closed")
            case .some(false):
                TileValue(
                    text: open.count == 1 ? open[0] : "\(open.count) open",
                    tone: .orange,
                    detail: open.count > 1 ? open.joined(separator: ", ") : nil
                )
            case nil:
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

/// Four pressures laid out like the car, front row on top.
struct TyresTile: View {
    let vehicle: VehicleState
    var marginBar: Double = 0.3

    var body: some View {
        let tyres = vehicle.tyres
        let low = vehicle.underinflatedTyres(margin: marginBar)
        Tile(title: "Tyres · bar", symbol: "tirepressure", tint: low.isEmpty ? .secondary : .orange) {
            if tyres.isEmpty {
                TileValue(text: "—", tone: .secondary)
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        pressure("Front left")
                        pressure("Front right")
                    }
                    GridRow {
                        pressure("Rear left")
                        pressure("Rear right")
                    }
                }
            }
        }
    }

    private func pressure(_ position: String) -> some View {
        let tyre = vehicle.tyres.first { $0.position == position }
        let isLow = (tyre?.deficitBar ?? 0) > marginBar
        return Text(tyre?.pressureBar.map { String(format: "%.1f", $0) } ?? "—")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isLow ? .orange : .primary)
            .frame(minWidth: 28, alignment: .leading)
    }
}

/// A tiny live map. Non-interactive; clicking opens Maps.
struct LocationTile: View {
    let vehicle: VehicleState

    var body: some View {
        if let location = vehicle.location {
            let coordinate = CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            )
            Tile(title: "Parked", symbol: "mappin.and.ellipse", padded: false) {
                Map(
                    initialPosition: .region(
                        MKCoordinateRegion(
                            center: coordinate,
                            latitudinalMeters: 500,
                            longitudinalMeters: 500
                        )
                    ),
                    interactionModes: []
                ) {
                    Marker("Car", systemImage: "car.fill", coordinate: coordinate)
                        .tint(Color.accentColor)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .mapControlVisibility(.hidden)
                // Re-create when the car moves; a parked car never does.
                .id("\(location.latitude),\(location.longitude)")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
            }
            .onTapGesture { NSWorkspace.shared.open(mapsURL(location)) }
        } else {
            Tile(title: "Parked", symbol: "mappin.slash") {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }

    private func mapsURL(_ location: VehicleLocation) -> URL {
        URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Car")!
    }
}

struct ClimateTile: View {
    let vehicle: VehicleState

    var body: some View {
        let active = vehicle.isPreconditioning
        Tile(
            title: "Climate",
            symbol: active ? "fan.fill" : "fan",
            tint: active ? VehicleMood.Tone.preconditioning.color : .secondary
        ) {
            if let state = vehicle.preconditioning, state != .unknown {
                TileValue(
                    text: active ? "Preconditioning" : "Off",
                    tone: active ? VehicleMood.Tone.preconditioning.color : .primary,
                    detail: vehicle.targetTemperatureCelsius.map { String(format: "Target %.0f °C", $0) }
                )
            } else {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

struct TripTile: View {
    let vehicle: VehicleState

    var body: some View {
        Tile(title: "Last trip", symbol: "road.lanes") {
            if let used = vehicle.lastTripConsumptionKWh {
                TileValue(
                    text: String(format: "%.1f kWh", used),
                    detail: vehicle.lastTripRecuperationKWh.map { String(format: "%.1f recuperated", $0) }
                )
            } else {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

struct OdometerTile: View {
    let vehicle: VehicleState

    var body: some View {
        Tile(title: "Odometer", symbol: "gauge.with.needle") {
            if let km = vehicle.odometerKm {
                TileValue(text: km.formatted(.number.precision(.fractionLength(0))) + " km")
            } else {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

struct EfficiencyTile: View {
    let vehicle: VehicleState

    var body: some View {
        Tile(title: "Average", symbol: "leaf") {
            if let consumption = vehicle[Descriptor.avgConsumption]?.doubleValue {
                TileValue(text: String(format: "%.1f", consumption), detail: "kWh / 100 km")
            } else {
                TileValue(text: "—", tone: .secondary)
            }
        }
    }
}

/// Recent sessions from the local stream log — the free replacement for BMW's REST
/// charging history.
struct ChargesTile: View {
    let sessions: [ChargingSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 9, weight: .semibold))
                Text("RECENT CHARGES")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                Spacer()
                Text("from the stream")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)

            if sessions.isEmpty {
                Text("None recorded yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.prefix(3)) { session in
                    SessionRow(session: session)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Tile<EmptyView>.corner, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tile<EmptyView>.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

}

private struct SessionRow: View {
    let session: ChargingSession

    private static let when: Date.FormatStyle = .dateTime.day().month(.abbreviated).hour().minute()

    var body: some View {
        let tone: Color = session.completedNormally ? .primary : .orange
        HStack {
            Text(session.startedAt, format: Self.when)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(describe(session))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tone)
        }
    }

    private func describe(_ session: ChargingSession) -> String {
        var parts: [String] = []
        if let gained = session.socGained, gained > 0 { parts.append("+\(Int(gained.rounded()))%") }
        if let energy = session.energyKWh { parts.append(String(format: "~%.1f kWh", energy)) }
        let minutes = Int(session.duration / 60)
        parts.append(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min")
        return parts.joined(separator: " · ")
    }
}
