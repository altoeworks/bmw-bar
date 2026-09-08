import SwiftUI

struct NotificationSettingsView: View {
    let model: AppModel
    @State private var preferences: NotificationPreferences
    @State private var thresholdEnabled: Bool

    init(model: AppModel) {
        self.model = model
        _preferences = State(initialValue: model.notifications)
        _thresholdEnabled = State(initialValue: model.notifications.socThreshold != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTIFICATIONS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            toggle("Charging started", \.chargingStarted)
            toggle("Charging finished", \.chargingFinished)
            toggle("Charging interrupted", \.chargingInterrupted)
            toggle("Plugged in but not charging", \.pluggedInButIdle)
            toggle("Left open", \.leftOpen)
            toggle("Alarm triggered", \.alarm)
            toggle("Tyre pressure low", \.tyrePressure)
            toggle("Preconditioning finished", \.preconditioningFinished)

            HStack(spacing: 6) {
                Toggle("At", isOn: $thresholdEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Stepper(
                    value: Binding(
                        get: { preferences.socThreshold ?? 80 },
                        set: { preferences.socThreshold = $0; commit() }
                    ),
                    in: 5...100,
                    step: 5
                ) {
                    Text("\(preferences.socThreshold ?? 80)%")
                        .font(.caption.monospacedDigit())
                }
                .disabled(!thresholdEnabled)
            }
            .onChange(of: thresholdEnabled) { _, enabled in
                preferences.socThreshold = enabled ? (preferences.socThreshold ?? 80) : nil
                commit()
            }

            Divider().opacity(0.4).padding(.vertical, 2)

            Text("WHILE CHARGING")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            Toggle(isOn: polling(\.enabled)) {
                Text("Fetch when the stream goes quiet mid-charge")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if model.polling.enabled {
                Stepper(value: polling(\.chargingIdleMinutes), in: 5...60, step: 5) {
                    Text("After \(model.polling.chargingIdleMinutes) min of silence")
                        .font(.caption.monospacedDigit())
                }
            }

            // The cost is the whole point of the trade-off, so it is stated up front.
            Text(pollingExplanation)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4).padding(.vertical, 2)

            Text("AFTER BEING AWAY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            Toggle(isOn: polling(\.resyncAfterGap)) {
                Text("Catch up after a long sleep")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if model.polling.resyncAfterGap {
                Stepper(value: polling(\.gapMinutes), in: 15...240, step: 15) {
                    Text("Gaps longer than \(model.polling.gapMinutes) min")
                        .font(.caption.monospacedDigit())
                }
                Stepper(value: polling(\.maxResyncsPerDay), in: 1...10, step: 1) {
                    Text("At most \(model.polling.maxResyncsPerDay) a day")
                        .font(.caption.monospacedDigit())
                }
            }

            Text(resyncExplanation)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let blocked = model.pollingBlockedReason {
                caption(blocked, systemImage: "exclamationmark.circle")
            }

            if case .unavailable(let reason) = model.notifier.availability {
                caption(reason, systemImage: "exclamationmark.triangle")
            } else if model.notifier.availability == .denied {
                caption(
                    "macOS is blocking notifications. Enable them in System Settings → Notifications.",
                    systemImage: "bell.slash"
                )
            }
        }
    }

    private func toggle(
        _ label: String,
        _ key: WritableKeyPath<NotificationPreferences, Bool>
    ) -> some View {
        Toggle(label, isOn: Binding(
            get: { preferences[keyPath: key] },
            set: { preferences[keyPath: key] = $0; commit() }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    /// Edits one field of the polling preferences, leaving the rest alone.
    private func polling<Value>(
        _ key: WritableKeyPath<PollingPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.polling[keyPath: key] },
            set: {
                var updated = model.polling
                updated[keyPath: key] = $0
                model.updatePolling(updated)
            }
        )
    }

    private func caption(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Spells out what the poll can cost, since it is the only thing in the app that
    /// spends BMW's budget without a click.
    private var pollingExplanation: String {
        guard model.polling.enabled else {
            return "The car publishes on events, not on a clock, so a charge can progress "
                + "for a long time with nothing sent. With this off, the ring simply "
                + "estimates until the car reports again."
        }
        let perHour = model.polling.callsPerHourWhileCharging
        let typical = model.polling.calls(forChargeLasting: 3)
        return "Only while charging — a parked car is never polled, so an idle day costs "
            + "nothing. About \(perHour) of BMW's 50 daily calls per hour of charging "
            + "(~\(typical) for a three-hour charge). These are non-essential, so they "
            + "stop early and always leave room for a manual fetch."
    }

    /// The wake-up catch-up is the second thing that can spend the budget unasked, so it
    /// gets the same plain accounting as the charging poll.
    private var resyncExplanation: String {
        guard model.polling.resyncAfterGap else {
            return "With this off, a gap is only ever reported, never filled. The panel "
                + "still marks which readings predate it."
        }
        return "While the Mac is asleep the app hears nothing. BMW usually replays what it "
            + "queued once the stream reconnects, and only when that does not happen is a "
            + "snapshot fetched — at most \(model.polling.maxResyncsPerDay) a day. A Mac "
            + "that sleeps overnight typically costs one call."
    }

    private func commit() {
        model.updateNotifications(preferences)
    }
}
