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

    private func caption(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func commit() {
        model.updateNotifications(preferences)
    }
}
