import Foundation

/// One charging session, reconstructed from the sample log.
public struct ChargingSession: Equatable, Sendable, Identifiable {
    public var id: Date { startedAt }

    public let startedAt: Date
    public let endedAt: Date
    public let startSoC: Double?
    public let endSoC: Double?
    /// Energy delivered, in kWh. An estimate — see `energyKWh(from:)`.
    public let energyKWh: Double?
    public let peakPowerKW: Double?
    /// How the session ended, in BMW's own vocabulary.
    public let endStatus: ChargingStatus?

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public var socGained: Double? {
        guard let startSoC, let endSoC else { return nil }
        return endSoC - startSoC
    }

    public var averagePowerKW: Double? {
        guard let energyKWh, duration > 0 else { return nil }
        return energyKWh / (duration / 3600)
    }

    /// Whether it stopped on its own terms rather than being cut short.
    public var completedNormally: Bool {
        switch endStatus {
        case .complete, .ended: return true
        default: return false
        }
    }
}

public enum ChargingSessionBuilder {
    /// Reconstructs sessions from a sample log.
    ///
    /// A session runs from the first actively-charging sample to the first sample that
    /// is no longer charging. Sessions still in progress at the end of the log are
    /// included, ending at the last sample.
    public static func sessions(from samples: [Sample]) -> [ChargingSession] {
        let ordered = samples.sorted { $0.at < $1.at }
        var sessions: [ChargingSession] = []
        var current: [Sample] = []

        for sample in ordered {
            if sample.isCharging {
                current.append(sample)
            } else if !current.isEmpty {
                // The first non-charging sample both closes the session and tells us
                // why it ended, so include it in the span but not in the power curve.
                sessions.append(make(current, terminator: sample))
                current = []
            }
        }
        if !current.isEmpty {
            sessions.append(make(current, terminator: nil))
        }
        return sessions
    }

    private static func make(_ charging: [Sample], terminator: Sample?) -> ChargingSession {
        let start = charging[0]
        let end = terminator ?? charging[charging.count - 1]

        return ChargingSession(
            startedAt: start.at,
            endedAt: end.at,
            startSoC: start.soc,
            endSoC: end.soc ?? charging.last?.soc,
            energyKWh: energyKWh(from: charging),
            peakPowerKW: charging.compactMap(\.powerKW).max(),
            endStatus: terminator?.chargingStatus
        )
    }

    /// Integrates the power curve over time, trapezoidally.
    ///
    /// Power is sampled irregularly — BMW reports when it feels like it — so each
    /// interval uses the mean of its two endpoints. This is an estimate whose accuracy
    /// tracks sample density; it is the only method available without the pack capacity,
    /// which now comes from a REST call the app may never make.
    public static func energyKWh(from samples: [Sample]) -> Double? {
        let points = samples.compactMap { sample -> (Date, Double)? in
            guard let power = sample.powerKW else { return nil }
            return (sample.at, power)
        }
        guard points.count >= 2 else { return nil }

        var total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let hours = b.0.timeIntervalSince(a.0) / 3600
            guard hours > 0 else { continue }
            total += (a.1 + b.1) / 2 * hours
        }
        return total > 0 ? total : nil
    }

    /// Energy from the state-of-charge delta, when the pack's usable capacity is known.
    /// More robust than integration for sparse logs, so it is preferred where possible.
    public static func energyKWh(
        startSoC: Double?,
        endSoC: Double?,
        capacityKWh: Double?
    ) -> Double? {
        guard let startSoC, let endSoC, let capacityKWh, endSoC > startSoC else { return nil }
        return (endSoC - startSoC) / 100 * capacityKWh
    }
}
