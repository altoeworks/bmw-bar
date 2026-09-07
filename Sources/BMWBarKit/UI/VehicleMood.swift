import SwiftUI

/// Maps vehicle state to one accent-and-motion pair.
///
/// Everything tinted — the ring, the chips, the menu bar icon — reads from here, so
/// they can never disagree about what the car is doing.
///
/// Motion is reserved for things actually happening. A resting car is completely still.
public struct VehicleMood: Equatable {
    public enum Motion: Equatable {
        case none
        /// A gradient travelling around the ring: current is flowing.
        case flow
        /// A slow radial breath behind the ring: preconditioning is running.
        case shimmer
        /// Both, layered — charging while preconditioning.
        case flowAndShimmer
    }

    public enum Tone: Equatable {
        case resting
        case charging
        case preconditioning
        case caution
        case fault

        public var color: Color {
            switch self {
            // Semantic colours resolve per light/dark scheme rather than fixed hex.
            case .resting: return .accentColor
            case .charging: return .green
            case .preconditioning: return .teal
            case .caution: return .orange
            case .fault: return .red
            }
        }
    }

    public let tone: Tone
    public let motion: Motion
    /// Always paired with the colour: colour alone is not a signal.
    public let symbol: String
    public let label: String

    public var color: Color { tone.color }

    public static let resting = VehicleMood(
        tone: .resting,
        motion: .none,
        symbol: "bolt.car",
        label: "Idle"
    )

    /// Derives the mood from current state. Charging outranks preconditioning for the
    /// ring's colour, because it is the thing changing the number.
    public static func from(_ state: VehicleState) -> VehicleMood {
        let preconditioning = state.isPreconditioning

        guard let status = state.chargingStatus else {
            return preconditioning
                ? VehicleMood(
                    tone: .preconditioning,
                    motion: .shimmer,
                    symbol: "fan.fill",
                    label: "Preconditioning"
                )
                : .resting
        }

        switch status {
        case .charging, .initialising:
            return VehicleMood(
                tone: .charging,
                motion: preconditioning ? .flowAndShimmer : .flow,
                symbol: "bolt.fill",
                label: status.displayName
            )

        case .paused:
            return VehicleMood(
                tone: .caution,
                motion: .none,
                symbol: "pause.circle.fill",
                label: status.displayName
            )

        case .error:
            return VehicleMood(
                tone: .fault,
                motion: .none,
                symbol: "exclamationmark.triangle.fill",
                label: status.displayName
            )

        case .complete, .ended:
            return VehicleMood(
                tone: .charging,
                motion: preconditioning ? .shimmer : .none,
                symbol: "checkmark.circle.fill",
                label: status.displayName
            )

        case .waiting:
            return VehicleMood(
                tone: .caution,
                motion: preconditioning ? .shimmer : .none,
                symbol: "clock.fill",
                label: status.displayName
            )

        case .notCharging, .unknown:
            if preconditioning {
                return VehicleMood(
                    tone: .preconditioning,
                    motion: .shimmer,
                    symbol: "fan.fill",
                    label: "Preconditioning"
                )
            }
            return VehicleMood(
                tone: .resting,
                motion: .none,
                symbol: "bolt.car",
                label: status.displayName
            )
        }
    }
}

/// A one-shot animation triggered by a discrete event, distinct from the continuous
/// motion of `VehicleMood`.
///
/// These come from `ChargingEventDetector` — the same source as the notifications — so
/// a banner and its matching pulse can never disagree.
public struct TransientCue: Equatable {
    public enum Kind: Equatable {
        /// One confident pulse: something good finished.
        case success
        /// Two quick pulses: something needs attention.
        case alert
    }

    public let kind: Kind
    public let tone: VehicleMood.Tone

    public init(kind: Kind, tone: VehicleMood.Tone) {
        self.kind = kind
        self.tone = tone
    }

    /// Not every event deserves a flash — a charge *starting* already shows itself
    /// through the ring beginning to flow.
    public init?(_ event: ChargingEvent) {
        switch event {
        case .finished:
            self.init(kind: .success, tone: .charging)
        case .thresholdReached:
            self.init(kind: .success, tone: .charging)
        case .interrupted(let status, _):
            self.init(kind: .alert, tone: status == .error ? .fault : .caution)
        case .pluggedInButIdle, .leftOpen, .tyrePressureLow:
            self.init(kind: .alert, tone: .caution)
        case .alarmTriggered:
            self.init(kind: .alert, tone: .fault)
        case .preconditioningFinished:
            self.init(kind: .success, tone: .preconditioning)
        case .started:
            // A charge starting already announces itself: the ring begins to flow.
            return nil
        }
    }
}
