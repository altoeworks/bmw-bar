import SwiftUI

/// The dashboard. Everything the car reports is visible at once, in a fixed grid, so
/// the eye learns where each reading lives. Settings — the only thing that isn't data —
/// sit behind the gear.
struct StatusPanel: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false

    static let width: CGFloat = 372
    private let gap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .needsClientID, .needsAuthorization, .awaitingApproval:
                OnboardingView(model: model)
            case .connecting:
                connecting
            case .ready:
                if showingSettings { settings } else { dashboard }
            case .failed(let message):
                failure(message)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .animation(.easeInOut(duration: 0.2), value: showingSettings)
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.isAwaitingFirstReport {
                awaitingFirstReport
            } else {
                hero
                grid
                ChargesTile(sessions: model.chargingSessions)
            }

            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.vehicle.vehicleName ?? "BMW")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(streamColor)
                    .frame(width: 6, height: 6)
                Text(shortStreamStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            ChargeRing(
                percent: model.vehicle.chargePercent,
                limitPercent: model.vehicle.chargeLimitPercent,
                mood: model.mood,
                cue: model.transientCue
            )
            .onChange(of: model.transientCue) { _, cue in
                guard cue != nil else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    model.consumeCue()
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(model.mood.label, systemImage: model.mood.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.mood.tone == .resting ? Color.primary : model.mood.color)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.vehicle.electricRangeKm.map { number($0) } ?? "—")
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("km")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Charging detail only while charging; otherwise the limit. Either way
                // the row is present, so the hero never jumps in height.
                Text(heroDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Sparkline(samples: model.recentSamples, tint: model.mood.color)
                    .frame(height: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heroDetail: String {
        if model.vehicle.isCharging {
            var parts: [String] = []
            if let power = model.vehicle.chargingPowerKW, power > 0 { parts.append("\(number(power)) kW") }
            if let plug = model.vehicle.chargingPlugType { parts.append(plug) }
            if let minutes = model.vehicle.chargingMinutesRemaining, minutes > 0 {
                parts.append("\(duration(minutes: minutes)) left")
            }
            return parts.isEmpty ? "Charging" : parts.joined(separator: " · ")
        }
        if let limit = model.vehicle.chargeLimitPercent {
            return "Charge limit \(number(limit))%"
        }
        return " "
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: 3)
        return LazyVGrid(columns: columns, spacing: gap) {
            PlugTile(vehicle: model.vehicle)
            SecurityTile(vehicle: model.vehicle)
            BodyTile(vehicle: model.vehicle)

            TyresTile(vehicle: model.vehicle, marginBar: model.notifications.tyreMarginBar)
            LocationTile(vehicle: model.vehicle)
            ClimateTile(vehicle: model.vehicle)

            TripTile(vehicle: model.vehicle)
            OdometerTile(vehicle: model.vehicle)
            EfficiencyTile(vehicle: model.vehicle)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let reading = model.vehicle.newestReadingTimestamp {
                Text("Reported \(reading, format: .relative(presentation: .named))")
            }
            if let quota = model.quota {
                Text("·")
                Text("\(quota.used)/\(quota.limit) API")
                    .help("BMW allows 50 REST calls a day. Live data arrives over the stream and is free.")
            }
            if let error = model.snapshotError {
                Text("·")
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            quitButton
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                // Balances the Back button so the title stays centred.
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .hidden()
            }

            NotificationSettingsView(model: model)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                Text("DATA")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.refreshSnapshot() }
                } label: {
                    if model.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fetch snapshot now")
                    }
                }
                .disabled(model.isFetching)
                Text("Uses 1 of BMW's 50 daily REST calls. Not normally needed — everything on the dashboard arrives over the stream for free.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Sign out") { Task { await model.signOut() } }
                    .font(.system(size: 11))
                Spacer()
                quitButton
            }
        }
    }

    // MARK: - Other states

    private var connecting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not connect", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try again") { Task { await model.start() } }
                Spacer()
                quitButton
            }
        }
    }

    private var awaitingFirstReport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for the car to report")
                .font(.system(size: 13, weight: .semibold))
            Text("""
                Nothing is fetched from BMW — data arrives over the stream when the car \
                has something to say. Waking it (locking or unlocking from the MyBMW \
                app) usually triggers an update.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.refreshSnapshot() }
            } label: {
                if model.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Fetch now (uses 1 of 50 daily calls)")
                }
            }
            .disabled(model.isFetching)
        }
    }

    private var quitButton: some View {
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private var streamColor: Color {
        switch model.streamStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .refused: return .red
        case .idle, .disconnected: return .secondary
        }
    }

    private var shortStreamStatus: String {
        switch model.streamStatus {
        case .connecting: return "Connecting"
        case .refused: return "In use elsewhere"
        case .disconnected: return "Offline"
        case .idle: return "Idle"
        case .connected: return "Live"
        }
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
