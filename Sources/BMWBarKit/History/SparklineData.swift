import Foundation

/// Downsamples the sample log into a fixed number of buckets for the panel's sparkline.
public enum SparklineData {
    /// - Parameters:
    ///   - buckets: how many points to produce. ~48 over 24 h is one every 30 minutes.
    /// - Returns: normalised points in 0...1 for both axes, oldest first, or an empty
    ///   array when there is not enough history to draw a line.
    public static func points(
        from samples: [Sample],
        window: TimeInterval = 24 * 60 * 60,
        buckets: Int = 48,
        now: Date = Date()
    ) -> [CGPoint] {
        let cutoff = now.addingTimeInterval(-window)
        let recent = samples
            .filter { $0.at >= cutoff && $0.soc != nil }
            .sorted { $0.at < $1.at }
        guard recent.count >= 2 else { return [] }

        let bucketed = bucket(recent, window: window, buckets: buckets, now: now)
        guard bucketed.count >= 2 else { return [] }

        // A flat line is legitimate (a parked car), so guard the zero-range divide
        // rather than dropping the series.
        let values = bucketed.map(\.1)
        let low = values.min()!
        let high = values.max()!
        let span = high - low

        return bucketed.enumerated().map { index, entry in
            CGPoint(
                x: CGFloat(index) / CGFloat(bucketed.count - 1),
                y: span > 0 ? CGFloat((entry.1 - low) / span) : 0.5
            )
        }
    }

    /// Averages samples into time buckets, skipping empty ones and carrying the last
    /// known value across gaps so a quiet car doesn't punch holes in the line.
    private static func bucket(
        _ samples: [Sample],
        window: TimeInterval,
        buckets: Int,
        now: Date
    ) -> [(Date, Double)] {
        let start = now.addingTimeInterval(-window)
        let width = window / Double(buckets)

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)

        for sample in samples {
            guard let soc = sample.soc else { continue }
            let offset = sample.at.timeIntervalSince(start)
            let index = min(buckets - 1, max(0, Int(offset / width)))
            sums[index] += soc
            counts[index] += 1
        }

        var result: [(Date, Double)] = []
        var carried: Double?
        for index in 0..<buckets {
            let value: Double?
            if counts[index] > 0 {
                value = sums[index] / Double(counts[index])
                carried = value
            } else {
                value = carried  // hold the previous reading across a silent stretch
            }
            if let value {
                result.append((start.addingTimeInterval(Double(index) * width), value))
            }
        }
        return result
    }

    /// The span the sparkline covers, for labelling.
    public static func range(of samples: [Sample], window: TimeInterval = 24 * 60 * 60, now: Date = Date())
        -> (low: Double, high: Double)?
    {
        let cutoff = now.addingTimeInterval(-window)
        let values = samples.filter { $0.at >= cutoff }.compactMap(\.soc)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, high)
    }
}
