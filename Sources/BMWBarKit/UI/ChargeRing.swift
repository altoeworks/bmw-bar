import SwiftUI

/// Charge level as a ring, tinted and animated by `VehicleMood`.
///
/// The limit tick shows where charging will stop. It is shown but not editable: BMW's
/// API has no way to change it.
struct ChargeRing: View {
    let percent: Double?
    let limitPercent: Double?
    let mood: VehicleMood
    /// A one-shot pulse, cleared by the parent once played.
    let cue: TransientCue?
    /// Whether `percent` is extrapolated rather than reported, which the ring marks
    /// with a "~" so an estimate is never mistaken for a reading.
    var isEstimated = false
    /// The car's own last reading, shown beneath the estimate so both numbers and the
    /// reading's age are visible without opening a panel.
    var reportedPercent: Double?
    var reportedAt: Date?
    /// Whether the app was listening when this was reported. An unconfirmed reading is
    /// still the last thing the car said — it just cannot be promised to be current.
    var confidence: Confidence = .confirmed

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 9
    // Slightly larger than the number alone needs: the reported value and its age sit
    // under it, inside the ring.
    private let diameter: CGFloat = 116

    @State private var pulse: CGFloat = 0

    var body: some View {
        ZStack {
            // Preconditioning reads as a soft breath *behind* the ring, so it can be
            // seen at the same time as charging without fighting it.
            if showsShimmer {
                ShimmerHalo(color: VehicleMood.Tone.preconditioning.color, animated: !reduceMotion)
            }

            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)

            if let percent {
                progressArc(percent: percent)
            }

            if let limitPercent, limitPercent > 0, limitPercent < 100 {
                LimitTick(percent: limitPercent, lineWidth: lineWidth)
            }

            centreLabel
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(1 + pulse * 0.06)
        .onChange(of: cue) { _, newValue in
            guard let newValue else { return }
            play(newValue)
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Pieces

    /// The filled arc, with a highlight travelling around it while charging so energy
    /// visibly flows into the ring.
    private func progressArc(percent: Double) -> some View {
        let fraction = min(max(percent, 0), 100) / 100
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        // `Shape.rotation` keeps this a Shape (unlike `rotationEffect`), so it can
        // still be used as a mask below.
        return Self.arc(fraction)
            .stroke(mood.color, style: style)
            .overlay {
                if showsFlow {
                    // Masking the rotating gradient to the arc keeps the highlight on
                    // the ring instead of sweeping the whole circle.
                    FlowOverlay(color: .white)
                        .mask(Self.arc(fraction).stroke(Color.white, style: style))
                }
            }
            .animation(.easeInOut(duration: 0.5), value: percent)
            .animation(.easeInOut(duration: 0.4), value: mood.tone)
    }

    /// The progress arc, starting at 12 o'clock.
    private static func arc(_ fraction: CGFloat) -> some Shape {
        Circle().trim(from: 0, to: fraction).rotation(.degrees(-90))
    }

    private var centreLabel: some View {
        VStack(spacing: 1) {
            if let percent {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if isEstimated {
                        Text("~")
                            .font(.system(size: 19, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .baselineOffset(1)
                }
                provenance
            } else {
                Text("—")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: diameter - lineWidth * 2 - 8)
    }

    /// Where the big number came from: the car's own reading and how old it is. While
    /// estimating both are shown, since the two numbers differ; otherwise the age alone
    /// is the useful part.
    @ViewBuilder
    private var provenance: some View {
        if let text = provenanceText {
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(confidence == .confirmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var provenanceText: String? {
        let age = reportedAt.map { Self.age(of: $0) }
        // An estimate extrapolates from a reading we trust. Across a gap there is nothing
        // to extrapolate from, so the honest thing is to date the reading and stop there.
        guard confidence == .confirmed else {
            return age.map { "last heard \($0)" } ?? "not heard from"
        }
        guard isEstimated, let reported = reportedPercent else {
            return age.map { "reported \($0)" }
        }
        let reportedText = "\(Int(reported.rounded()))%"
        return age.map { "was \(reportedText) · \($0)" } ?? "was \(reportedText)"
    }

    /// Compact enough to fit inside the ring. Shared with the detail panels' freshness
    /// lines so one reading is never described two different ways in one window.
    static func age(of date: Date, now: Date = Date()) -> String {
        Freshness.age(of: date, now: now)
    }

    // MARK: - Motion

    private var showsFlow: Bool {
        !reduceMotion && (mood.motion == .flow || mood.motion == .flowAndShimmer)
    }

    private var showsShimmer: Bool {
        mood.motion == .shimmer || mood.motion == .flowAndShimmer
    }

    private func play(_ cue: TransientCue) {
        guard !reduceMotion else { return }
        let beats = cue.kind == .success ? 1 : 2
        for beat in 0..<beats {
            let delay = Double(beat) * 0.28
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45).delay(delay)) {
                pulse = 1
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(delay + 0.14)) {
                pulse = 0
            }
        }
    }

    private var accessibilityText: String {
        guard let percent else { return "Charge level unknown" }
        var text = "Charge \(isEstimated ? "estimated " : "")\(Int(percent.rounded())) percent, \(mood.label)"
        if isEstimated, let reported = reportedPercent {
            text += ", last reported \(Int(reported.rounded())) percent"
        }
        if let reportedAt { text += " \(Self.age(of: reportedAt))" }
        if confidence == .unconfirmed { text += ", unconfirmed since the app lost touch" }
        if let limitPercent { text += ", limit \(Int(limitPercent.rounded())) percent" }
        return text
    }
}

/// The rotating highlight that makes the charging ring look like it is flowing.
private struct FlowOverlay: View {
    let color: Color
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [.clear, color.opacity(0.55), .clear]),
                    center: .center
                )
            )
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// A slow radial breath, used for preconditioning.
private struct ShimmerHalo: View {
    let color: Color
    let animated: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.28), .clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: 62
                )
            )
            .scaleEffect(expanded ? 1.12 : 0.94)
            .opacity(expanded ? 0.9 : 0.55)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    expanded = true
                }
            }
    }
}

/// A short radial mark on the ring showing where charging will stop.
private struct LimitTick: View {
    let percent: Double
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            let angle = Angle.degrees(percent / 100 * 360 - 90)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            Path { path in
                path.move(to: point(from: center, angle: angle, distance: radius - lineWidth))
                path.addLine(to: point(from: center, angle: angle, distance: radius + 1))
            }
            .stroke(Color.primary.opacity(0.5), lineWidth: 2)
        }
    }

    private func point(from center: CGPoint, angle: Angle, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle.radians) * distance,
            y: center.y + sin(angle.radians) * distance
        )
    }
}
