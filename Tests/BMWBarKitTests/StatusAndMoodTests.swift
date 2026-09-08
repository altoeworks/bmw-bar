import Foundation
import Testing
@testable import BMWBarKit

@Suite("Openings and security")
struct OpeningsTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// BMW reports CLOSED / INTERMEDIATE / OPEN / INVALID. A window left ajar is
    /// exactly the case worth catching, so INTERMEDIATE counts as open.
    @Test func ajarWindowCountsAsOpen() {
        #expect(OpeningState(raw: "CLOSED")?.isOpen == false)
        #expect(OpeningState(raw: "INTERMEDIATE")?.isOpen == true)
        #expect(OpeningState(raw: "OPEN")?.isOpen == true)
        // Placeholders are unknown, never silently "closed".
        #expect(OpeningState(raw: "INVALID") == nil)
        #expect(OpeningState(raw: "-NA-") == nil)
    }

    @Test func listsWhatIsOpen() {
        let s = state([
            Descriptor.doorFrontLeft: TelematicValue(raw: .bool(true)),
            Descriptor.doorRearRight: TelematicValue(raw: .bool(false)),
            Descriptor.windowFrontRight: TelematicValue(raw: .string("INTERMEDIATE")),
            Descriptor.trunkOpen: TelematicValue(raw: .bool(false)),
        ])
        #expect(s.openThings.count == 2)
        #expect(s.isAllClosed == false)
    }

    @Test func allClosedWhenEverythingReportsShut() {
        let s = state([
            Descriptor.doorFrontLeft: TelematicValue(raw: .bool(false)),
            Descriptor.windowFrontLeft: TelematicValue(raw: .string("CLOSED")),
            Descriptor.trunkOpen: TelematicValue(raw: .bool(false)),
        ])
        #expect(s.isAllClosed == true)
        #expect(s.openThings.isEmpty)
    }

    /// Nothing reported means unknown — not "all closed", which would be a lie.
    @Test func unknownWhenNothingReported() {
        #expect(state([:]).isAllClosed == nil)
    }

    /// There is no central-locking descriptor; the alarm is the honest proxy.
    @Test func alarmArmStateMapsBMWsVocabulary() {
        #expect(AlarmArmState(raw: "unarmed") == .unarmed)
        #expect(AlarmArmState(raw: "doorsOnly") == .doorsOnly)
        #expect(AlarmArmState(raw: "doorsTiltCabin") == .doorsAndInterior)
        #expect(!AlarmArmState(raw: "unarmed").isArmed)
        #expect(AlarmArmState(raw: "doorsOnly").isArmed)
        #expect(AlarmArmState(raw: "doorsTiltCabin").isArmed)
        // And it must never claim to be a lock.
        #expect(!AlarmArmState(raw: "doorsOnly").displayName.lowercased().contains("lock"))
    }
}

@Suite("Tyres")
struct TyreTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// BMW streams kPa; 250 kPa is 2.5 bar.
    @Test func convertsKilopascalToBar() {
        let s = state([
            Descriptor.tyreFrontLeftPressure: TelematicValue(raw: .number(250), unit: "kPa"),
            Descriptor.tyreFrontLeftTarget: TelematicValue(raw: .number(260), unit: "kPa"),
        ])
        let tyre = s.tyres[0]
        #expect(tyre.pressureBar == 2.5)
        #expect(tyre.targetBar == 2.6)
        #expect(abs((tyre.deficitBar ?? 0) - 0.1) < 0.0001)
    }

    @Test func flagsOnlyTyresBelowTheMargin() {
        let s = state([
            Descriptor.tyreFrontLeftPressure: TelematicValue(raw: .number(200)),
            Descriptor.tyreFrontLeftTarget: TelematicValue(raw: .number(260)),
            Descriptor.tyreRearRightPressure: TelematicValue(raw: .number(255)),
            Descriptor.tyreRearRightTarget: TelematicValue(raw: .number(260)),
        ])
        let low = s.underinflatedTyres(margin: 0.2)
        #expect(low.count == 1)
        #expect(low[0].position == "Front left")
    }

    @Test func skipsWheelsThatNeverReported() {
        #expect(state([:]).tyres.isEmpty)
    }
}

@Suite("Location and climate")
struct LocationClimateTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    @Test func readsCoordinates() {
        let s = state([
            Descriptor.latitude: TelematicValue(raw: .number(48.1371)),
            Descriptor.longitude: TelematicValue(raw: .number(11.5754)),
        ])
        #expect(s.location?.latitude == 48.1371)
        #expect(s.location?.longitude == 11.5754)
    }

    /// BMW sends 0,0 when it has no GPS fix — that is not the Gulf of Guinea.
    @Test func rejectsNullIsland() {
        let s = state([
            Descriptor.latitude: TelematicValue(raw: .number(0)),
            Descriptor.longitude: TelematicValue(raw: .number(0)),
        ])
        #expect(s.location == nil)
    }

    @Test func mapsPreconditioningStates() {
        #expect(PreconditioningState(raw: "OFF") == .off)
        #expect(PreconditioningState(raw: "REMOTE_OFF") == .off)
        #expect(PreconditioningState(raw: "AUTOMATIC_ON").isActive)
        #expect(PreconditioningState(raw: "MANUAL_ON_CHARGE").isActive)
        #expect(PreconditioningState(raw: "UNKNOWN") == .unknown)
    }

    /// Three descriptors report this; any one saying "running" wins.
    @Test func anySourceReportingActivityWins() {
        let s = state([
            Descriptor.preconditioningState: TelematicValue(raw: .string("OFF")),
            Descriptor.preconditioningManual: TelematicValue(raw: .string("ON_CHARGE")),
        ])
        #expect(s.isPreconditioning)
    }
}

@Suite("Vehicle mood")
struct VehicleMoodTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    @Test func chargingFlows() {
        let mood = VehicleMood.from(
            state([Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGINGACTIVE"))])
        )
        #expect(mood.tone == .charging)
        #expect(mood.motion == .flow)
    }

    @Test func preconditioningShimmers() {
        let mood = VehicleMood.from(state([
            Descriptor.chargingStatus: TelematicValue(raw: .string("NOCHARGING")),
            Descriptor.preconditioningState: TelematicValue(raw: .string("AUTOMATIC_ON")),
        ]))
        #expect(mood.tone == .preconditioning)
        #expect(mood.motion == .shimmer)
    }

    /// Both at once: the ring stays authoritative, the halo layers behind it.
    @Test func chargingWhilePreconditioningLayersBoth() {
        let mood = VehicleMood.from(state([
            Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGINGACTIVE")),
            Descriptor.preconditioningState: TelematicValue(raw: .string("AUTOMATIC_ON")),
        ]))
        #expect(mood.tone == .charging)
        #expect(mood.motion == .flowAndShimmer)
    }

    @Test func faultsAndPausesAreStill() {
        let error = VehicleMood.from(
            state([Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGINGERROR"))])
        )
        #expect(error.tone == .fault)
        #expect(error.motion == .none)

        let paused = VehicleMood.from(
            state([Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGINGPAUSED"))])
        )
        #expect(paused.tone == .caution)
        #expect(paused.motion == .none)
    }

    /// A resting car must be completely still.
    @Test func restingHasNoMotion() {
        let mood = VehicleMood.from(
            state([Descriptor.chargingStatus: TelematicValue(raw: .string("NOCHARGING"))])
        )
        #expect(mood.tone == .resting)
        #expect(mood.motion == .none)
    }

    /// Colour is never the only signal — every mood carries an icon and words.
    @Test func everyMoodPairsColourWithIconAndText() {
        let states = ["CHARGINGACTIVE", "NOCHARGING", "CHARGINGERROR", "CHARGINGPAUSED",
                      "FINISHED_FULLY_CHARGED", "WAITING_FOR_CHARGING"]
        for raw in states {
            let mood = VehicleMood.from(
                state([Descriptor.chargingStatus: TelematicValue(raw: .string(raw))])
            )
            #expect(!mood.symbol.isEmpty, "no symbol for \(raw)")
            #expect(!mood.label.isEmpty, "no label for \(raw)")
        }
    }
}

@Suite("Transient cues")
struct TransientCueTests {
    /// A charge starting already shows itself — the ring begins to flow.
    @Test func startingRaisesNoCue() {
        #expect(TransientCue(.started(percent: 40)) == nil)
    }

    @Test func finishingPulsesOnce() {
        let cue = TransientCue(.finished(percent: 80, reachedLimit: true))
        #expect(cue?.kind == .success)
        #expect(cue?.tone == .charging)
    }

    @Test func problemsPulseTwice() {
        #expect(TransientCue(.interrupted(status: .error, percent: 50))?.kind == .alert)
        #expect(TransientCue(.interrupted(status: .error, percent: 50))?.tone == .fault)
        #expect(TransientCue(.interrupted(status: .paused, percent: 50))?.tone == .caution)
        #expect(TransientCue(.alarmTriggered)?.tone == .fault)
        #expect(TransientCue(.pluggedInButIdle(minutes: 5))?.kind == .alert)
    }
}

@Suite("Stream VIN discovery")
struct VINDiscoveryTests {
    /// Recovering the VIN from the stream is what removes the last mandatory REST call.
    @Test func extractsVINFromTopic() {
        #expect(
            CarDataStream.vin(fromTopic: "41c477fd-5714-4a2c/WBYTESTVIN1234567")
                == "WBYTESTVIN1234567"
        )
    }

    /// A wildcard subscription's own topic pattern is not a VIN.
    @Test func ignoresWildcardAndMalformedTopics() {
        #expect(CarDataStream.vin(fromTopic: "41c477fd-5714-4a2c/+") == nil)
        #expect(CarDataStream.vin(fromTopic: "nogcid") == nil)
        #expect(CarDataStream.vin(fromTopic: "") == nil)
    }

    /// The payload carries it too, which is the primary source.
    @Test func messageCarriesTheVIN() throws {
        let message = try JSONDecoder().decode(
            StreamMessage.self,
            from: Data(#"{"vin":"WBYTESTVIN1234567","data":{}}"#.utf8)
        )
        #expect(message.vin == "WBYTESTVIN1234567")
    }
}

@Suite("Plug descriptors")
struct PlugDescriptorTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// The AC/DC prefix is dropped: the Charging panel already breaks out AC voltage,
    /// current and phase count, and a tile column is too narrow to spend on it.
    @Test func namesTheAcPlugTypes() {
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("AC_TYPE2PLUG"))])
                .chargingPlugType == "Type 2"
        )
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("AC_TYPE1PLUG"))])
                .chargingPlugType == "Type 1"
        )
    }

    /// BMW sends NOCHARGING rather than omitting the field when nothing is connected —
    /// that must read as "no plug", not as a plug type called "Nocharging".
    @Test func treatsPlaceholdersAsNoPlug() {
        for raw in ["NOCHARGING", "INVALID", "-NA-"] {
            #expect(
                state([Descriptor.chargingMethod: TelematicValue(raw: .string(raw))])
                    .chargingPlugType == nil,
                "\(raw) should not read as a plug type"
            )
        }
    }

    /// A real i4 streams `AC_TYP2COMBO`, which is *not* in BMW's documented range of
    /// AC_TYPE1PLUG / AC_TYPE2PLUG / NOCHARGING. The documented range is not exhaustive.
    @Test func handlesTheUndocumentedValueARealI4Sends() {
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("AC_TYP2COMBO"))])
                .chargingPlugType == "Type 2 Combo"
        )
    }

    @Test func namesDCPlugs() {
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("DC_CCS"))])
                .chargingPlugType == "CCS"
        )
    }

    /// Whatever BMW invents next must still read as words — never "Ac Typ2Combo",
    /// which is what a blanket `.capitalized` produced.
    @Test func tidiesUnknownPlugValuesInsteadOfCapitalisingThem() {
        let tidied = VehicleState.tidyPlugName("AC_TYP3PLUG")
        #expect(tidied == "Type 3")
        #expect(!tidied.contains("_"))
        #expect(!tidied.hasPrefix("Ac"))
    }

    /// This one is a vehicle setting, not a live state.
    @Test func readsPlugAutoUnlockSetting() {
        #expect(
            state([Descriptor.plugAutoUnlock: TelematicValue(raw: .bool(true))])
                .plugUnlocksAutomatically == true
        )
        #expect(state([:]).plugUnlocksAutomatically == nil)
    }
}

@Suite("Range sources")
struct RangeSourceTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// The i4 streams `lastRemainingRange` — catalogued as ICE/PHEV/MHEV — while the
    /// BEV-specific descriptor stays silent. Without this fallback the panel shows no
    /// range at all.
    @Test func fallsBackToTheRangeAnI4ActuallySends() {
        #expect(
            state([Descriptor.lastRemainingRange: TelematicValue(raw: .number(235), unit: "km")])
                .electricRangeKm == 235
        )
    }

    /// When both exist, the *fresher* one wins — a stale BEV-specific value from an old
    /// REST snapshot must not outrank what the car streamed a minute ago.
    @Test func newestReadingWinsRegardlessOfDescriptor() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        #expect(
            state([
                Descriptor.electricRange: TelematicValue(raw: .number(240), timestamp: old),
                Descriptor.lastRemainingRange: TelematicValue(raw: .number(235), unit: "km", timestamp: new),
            ]).electricRangeKm == 235
        )
        #expect(
            state([
                Descriptor.electricRange: TelematicValue(raw: .number(240), timestamp: new),
                Descriptor.lastRemainingRange: TelematicValue(raw: .number(235), unit: "km", timestamp: old),
            ]).electricRangeKm == 240
        )
    }

    @Test func nilWhenNeitherArrives() {
        #expect(state([:]).electricRangeKm == nil)
    }
}

@Suite("Body openings and locking")
struct BodyOpeningTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// Of 245 catalogued descriptors only two concern locking, so the boot is the one
    /// point where open and locked are independently known.
    @Test func bootReportsOpenAndLockedSeparately() {
        let s = state([
            Descriptor.trunkOpen: TelematicValue(raw: .bool(false)),
            Descriptor.trunkLocked: TelematicValue(raw: .bool(false)),
        ])
        let boot = try! #require(s.bodyOpenings.first { $0.kind == .boot })
        #expect(boot.isOpen == false)
        #expect(boot.isLocked == false)
        #expect(boot.openingText == "Closed")
        #expect(boot.lockText == "Unlocked")
    }

    /// A shut car with an unlocked boot is not "all secure" — the tile must still warn.
    @Test func closedButUnlockedIsSurfaced() {
        let s = state([
            Descriptor.doorFrontLeft: TelematicValue(raw: .bool(false)),
            Descriptor.trunkOpen: TelematicValue(raw: .bool(false)),
            Descriptor.trunkLocked: TelematicValue(raw: .bool(false)),
        ])
        #expect(s.isAllClosed == true)
        #expect(s.unlockedThings.map(\.name) == ["Boot"])
    }

    /// Doors and windows have no lock descriptor at all; claiming otherwise would be
    /// inventing data.
    @Test func doorsAndWindowsNeverClaimALockState() {
        let s = state([
            Descriptor.doorFrontLeft: TelematicValue(raw: .bool(false)),
            Descriptor.windowFrontLeft: TelematicValue(raw: .string("CLOSED")),
        ])
        for point in s.bodyOpenings where point.kind == .door || point.kind == .window {
            #expect(point.isLocked == nil, "\(point.name) must not report a lock")
            #expect(point.lockText == nil)
        }
    }

    /// The charge flap is the mirror image: a lock but no open/closed reading.
    @Test func chargeFlapReportsOnlyItsLock() {
        let s = state([Descriptor.chargeFlapLocked: TelematicValue(raw: .bool(true))])
        let flap = try! #require(s.bodyOpenings.first { $0.kind == .chargeFlap })
        #expect(flap.isLocked == true)
        #expect(flap.opening == nil)
        #expect(flap.openingText == "—")
    }

    /// INTERMEDIATE is the case worth catching — a window left ajar.
    @Test func ajarWindowIsItsOwnState() {
        let s = state([Descriptor.windowFrontLeft: TelematicValue(raw: .string("INTERMEDIATE"))])
        let window = try! #require(s.bodyOpenings.first { $0.id == Descriptor.windowFrontLeft })
        #expect(window.opening == .ajar)
        #expect(window.openingText == "Ajar")
        #expect(window.isOpen == true)
        #expect(s.openThings.count == 1)
    }

    /// Every point is listed whether or not it reported, so the panel's layout is stable.
    @Test func allPointsAreListedEvenWhenSilent() {
        let points = state([:]).bodyOpenings
        #expect(points.count == 12)  // 4 doors, 4 windows + tailgate glass, boot, bonnet, flap
        #expect(points.allSatisfy { $0.opening == nil && $0.isLocked == nil })
        #expect(Set(points.map(\.group)) == ["Doors", "Windows", "Other"])
        // Ids are the descriptors, so they are unique and stable for SwiftUI identity.
        #expect(Set(points.map(\.id)).count == points.count)
    }

    /// Unreported points must not be counted as closed.
    @Test func silenceIsNotClosed() {
        #expect(state([:]).isAllClosed == nil)
        #expect(state([:]).openThings.isEmpty)
        #expect(state([:]).lockableThings.isEmpty)
    }
}

@Suite("Charge prediction between reports")
struct ChargePredictionTests {
    private let reportedAt = Date(timeIntervalSince1970: 1_788_782_400)

    /// Mirrors the real i4 gap: 64% at 10.55 kW into a 66 kWh pack.
    private func charging(
        soc: Double = 64,
        powerKW: Double = 10.55,
        capacity: Double = 66,
        limit: Double? = 100,
        status: String = "CHARGINGACTIVE"
    ) -> VehicleState {
        let state = VehicleState()
        var values: [String: TelematicValue] = [
            Descriptor.socHeader: TelematicValue(raw: .number(soc), unit: "percent", timestamp: reportedAt),
            Descriptor.chargingStatus: TelematicValue(raw: .string(status), timestamp: reportedAt),
            Descriptor.chargingPower: TelematicValue(raw: .number(powerKW * 1000), unit: "W", timestamp: reportedAt),
            Descriptor.maxEnergy: TelematicValue(raw: .number(capacity), unit: "kWh", timestamp: reportedAt),
        ]
        if let limit {
            values[Descriptor.socTarget] = TelematicValue(raw: .number(limit), timestamp: reportedAt)
        }
        state.merge(values)
        return state
    }

    /// The case that prompted this: 22 minutes of charging with no message at all.
    /// The car later reported 69%; this must land close, not sit frozen at 64%.
    @Test func fillsTheGapDuringACharge() throws {
        let state = charging()
        let predicted = try #require(
            state.predictedChargePercent(asOf: reportedAt.addingTimeInterval(22.4 * 60))
        )
        #expect(abs(predicted - 70) < 0.2)
        #expect(state.isChargeEstimated(asOf: reportedAt.addingTimeInterval(22.4 * 60)))
    }

    /// A parked car must never have its number invented.
    @Test func doesNotPredictWhenNotCharging() {
        let state = charging(status: "NOCHARGING")
        #expect(state.predictedChargePercent(asOf: reportedAt.addingTimeInterval(3600)) == nil)
        #expect(state.displayChargePercent(asOf: reportedAt.addingTimeInterval(3600)) == 64)
        #expect(!state.isChargeEstimated(asOf: reportedAt.addingTimeInterval(3600)))
    }

    /// Charging stops at the limit, so the estimate must not sail past it.
    @Test func clampsToTheChargeLimit() throws {
        let state = charging(soc: 78, limit: 80)
        let predicted = try #require(
            state.predictedChargePercent(asOf: reportedAt.addingTimeInterval(6 * 3600))
        )
        #expect(predicted == 80)
    }

    @Test func clampsTo100WhenNoLimitReported() throws {
        let state = charging(soc: 95, limit: nil)
        let predicted = try #require(
            state.predictedChargePercent(asOf: reportedAt.addingTimeInterval(6 * 3600))
        )
        #expect(predicted == 100)
    }

    /// Without power or capacity there is nothing to extrapolate from — fall back to
    /// the reading rather than guessing.
    @Test func needsPowerAndCapacity() {
        let noPower = charging(powerKW: 0)
        #expect(noPower.predictedChargePercent(asOf: reportedAt.addingTimeInterval(3600)) == nil)
        #expect(noPower.displayChargePercent(asOf: reportedAt.addingTimeInterval(3600)) == 64)
    }

    /// A fresh reading is not an estimate, so the UI must not label it one.
    @Test func isNotEstimatedImmediatelyAfterAReading() {
        let state = charging()
        #expect(!state.isChargeEstimated(asOf: reportedAt))
        #expect(state.displayChargePercent(asOf: reportedAt) == 64)
    }

    /// Any real reading replaces the extrapolation outright.
    @Test func aNewReadingResetsTheBaseline() throws {
        let state = charging()
        let later = reportedAt.addingTimeInterval(22 * 60)
        #expect(try #require(state.predictedChargePercent(asOf: later)) > 69)

        state.merge([
            Descriptor.socHeader: TelematicValue(raw: .number(69), unit: "percent", timestamp: later)
        ])
        // Predicting from the new baseline at the same instant means no drift yet.
        #expect(state.predictedChargePercent(asOf: later) == nil || state.chargePercent == 69)
        #expect(state.displayChargePercent(asOf: later) == 69)
    }
}

@Suite("Charge ring provenance")
struct ChargeRingProvenanceTests {
    private let now = Date(timeIntervalSince1970: 1_788_782_400)

    /// The ring carries the reading's age, so it has to read compactly inside a circle.
    @Test func formatsAgeCompactly() {
        #expect(ChargeRing.age(of: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(ChargeRing.age(of: now.addingTimeInterval(-22 * 60), now: now) == "22m ago")
        #expect(ChargeRing.age(of: now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
        #expect(ChargeRing.age(of: now.addingTimeInterval(-49 * 3600), now: now) == "2d ago")
    }

    /// A clock skew must not produce a negative age.
    @Test func handlesAFutureTimestamp() {
        #expect(ChargeRing.age(of: now.addingTimeInterval(60), now: now) == "just now")
    }
}
