import SwiftUI

/// The status bar title: charge percentage plus a battery/bolt glyph.
///
/// Kept deliberately narrow — the menu bar is scarce space, and anything beyond the
/// number belongs in the panel.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if let text = percentText {
                Text(text)
                    .monospacedDigit()
            }
        }
    }

    private var percentText: String? {
        guard let percent = model.vehicle.chargePercent else { return nil }
        return "\(Int(percent.rounded()))%"
    }

    /// The icon deliberately does not animate. A permanently moving menu bar item is a
    /// battery and attention cost the design does not justify; motion lives in the
    /// panel, which macOS tears down when closed.
    private var symbolName: String {
        if model.vehicle.isCharging { return "bolt.fill" }
        if model.vehicle.isPreconditioning { return "fan.fill" }

        guard let percent = model.vehicle.chargePercent else {
            // Nothing known yet, or not signed in.
            return "bolt.car"
        }
        switch percent {
        case ..<12.5: return "battery.0percent"
        case ..<37.5: return "battery.25percent"
        case ..<62.5: return "battery.50percent"
        case ..<87.5: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
