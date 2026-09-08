import SwiftUI

/// Which drill-down panel is open, if any.
///
/// The dashboard stays the whole story at a glance; a detail panel is for the reading
/// behind a summary — the four individual tyre pressures behind "2.3", every door and
/// window behind "All closed".
public enum DashboardDetail: String, Identifiable, CaseIterable {
    case charging
    case security
    case body
    case tyres
    case location
    case climate
    case trip

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .charging: return "Charging"
        case .security: return "Security"
        case .body: return "Body"
        case .tyres: return "Tyres"
        case .location: return "Location"
        case .climate: return "Climate"
        case .trip: return "Trip & efficiency"
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "powerplug"
        case .security: return "shield"
        case .body: return "car.side"
        case .tyres: return "tirepressure"
        case .location: return "mappin.and.ellipse"
        case .climate: return "fan"
        case .trip: return "road.lanes"
        }
    }
}

extension View {
    /// Makes a tile open a detail panel: click target, pointer cursor, a chevron so it
    /// reads as tappable, and a small press response.
    func opensDetail(_ detail: DashboardDetail, selection: Binding<DashboardDetail?>) -> some View {
        modifier(OpensDetail(detail: detail, selection: selection))
    }
}

private struct OpensDetail: ViewModifier {
    let detail: DashboardDetail
    @Binding var selection: DashboardDetail?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(7)
                    .opacity(hovering ? 1 : 0.45)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.04 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { selection = detail }
            .onHover { inside in
                hovering = inside
                // The tiles are not controls, so the cursor is the main affordance.
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens \(detail.title) detail")
    }
}

// MARK: - Shared building blocks

/// A label/value line, the backbone of every detail panel.
struct DetailRow: View {
    let label: String
    var value: String?
    var tone: Color = .primary
    var badge: String?
    var badgeTone: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(badgeTone)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(badgeTone.opacity(0.13)))
            }
            Text(value ?? "—")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : tone)
        }
    }
}

/// A titled group of rows inside a detail panel.
struct DetailSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
            VStack(spacing: 3) { content }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }
}

/// Shown when a panel's descriptors have never arrived, naming the reason rather than
/// leaving an empty box.
struct DetailEmpty: View {
    var body: some View {
        Text("""
            Nothing reported yet. These fields only stream once ticked under \
            "Configure data stream" in the MyBMW portal, and some only populate while \
            the car is charging or driving.
            """)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
