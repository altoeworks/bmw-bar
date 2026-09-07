import SwiftUI

/// A compact charge-over-time line, drawn from the local sample log.
///
/// The history is recorded from the stream, so this costs nothing — it is the visible
/// half of not needing BMW's REST `chargingHistory` endpoint.
struct Sparkline: View {
    let samples: [Sample]
    let tint: Color
    var window: TimeInterval = 24 * 60 * 60

    private var points: [CGPoint] { SparklineData.points(from: samples, window: window) }

    var body: some View {
        if points.count >= 2 {
            HStack(spacing: 8) {
                chart
                    .frame(height: 22)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    private var chart: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let path = Path { path in
                for (index, point) in points.enumerated() {
                    // y is normalised 0...1 low-to-high, but screen y grows downward.
                    let position = CGPoint(
                        x: point.x * size.width,
                        y: (1 - point.y) * size.height
                    )
                    index == 0 ? path.move(to: position) : path.addLine(to: position)
                }
            }

            ZStack {
                // A soft fill under the line gives it weight without adding clutter.
                path
                    .addingFill(to: size)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                path.stroke(
                    tint.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private var caption: String {
        guard let range = SparklineData.range(of: samples, window: window) else { return "24h" }
        return range.high - range.low < 1
            ? "24h"
            : "\(Int(range.low.rounded()))–\(Int(range.high.rounded()))%"
    }
}

private extension Path {
    /// Closes the line down to the baseline so it can be filled.
    func addingFill(to size: CGSize) -> Path {
        var filled = self
        guard let last = currentPoint else { return filled }
        filled.addLine(to: CGPoint(x: last.x, y: size.height))
        filled.addLine(to: CGPoint(x: 0, y: size.height))
        filled.closeSubpath()
        return filled
    }
}
