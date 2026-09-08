import SwiftUI

/// How the app talks about the age of a reading.
///
/// The panel used to imply one freshness for everything on it — a green "Live" dot and a
/// single age on the ring — while the underlying values were stamped anything from
/// seconds to a day apart. These are the pieces that say which is which.
enum Freshness {
    /// Compact relative age: "just now", "22m ago", "3h ago", "2d ago".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    /// The same span without the "ago", for chips where space is tight.
    static func span(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 90 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }

    /// Amber is reserved for "this might have changed without us", never for "this is
    /// merely old" — a car that has sat still for a week is not a problem.
    static func tone(_ confidence: Confidence) -> Color {
        confidence == .confirmed ? .secondary : .orange
    }
}

/// One line saying how old a panel's own facts are, and whether they can be vouched for.
///
/// Sits under a detail panel's title, because each panel draws on a different set of
/// descriptors and they genuinely disagree: location can be from last night while the
/// tyres were read this morning.
struct FreshnessLine: View {
    let reportedAt: Date?
    let confidence: Confidence

    var body: some View {
        HStack(spacing: 4) {
            if confidence == .unconfirmed {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9))
        }
        .foregroundStyle(Freshness.tone(confidence))
        .help(help)
    }

    private var text: String {
        guard let reportedAt else {
            return confidence == .confirmed ? "Not reported" : "Never reported"
        }
        let age = Freshness.age(of: reportedAt)
        return confidence == .confirmed ? "Reported \(age)" : "Last reported \(age), before a gap"
    }

    private var help: String {
        switch confidence {
        case .confirmed:
            return "The app was connected when this was reported, so anything that changed "
                + "since would have arrived."
        case .unconfirmed:
            return "This was reported before the app lost touch with BMW. It is the last "
                + "thing the car said, but it may have changed since."
        }
    }
}

/// The strip that appears after the Mac has been away long enough for the car to have
/// changed unseen.
///
/// Deliberately not styled as an error: nothing is broken, the app simply cannot claim to
/// know. It offers the one action that would settle it, priced honestly.
struct GapBanner: View {
    let gap: CoverageGap
    let isFetching: Bool
    let refresh: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(gap.cause.reason.capitalized) for \(gap.shortDuration)")
                    .font(.system(size: 11, weight: .semibold))
                Text("The car may have changed while the app was out of touch.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if isFetching {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", action: refresh)
                    .font(.system(size: 10, weight: .medium))
                    .help("Fetches one snapshot. Uses 1 of BMW's 50 daily calls.")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.11))
        )
    }
}
