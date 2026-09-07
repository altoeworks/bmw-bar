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

    @Test func namesTheAcPlugTypes() {
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("AC_TYPE2PLUG"))])
                .chargingPlugType == "AC Type 2"
        )
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("AC_TYPE1PLUG"))])
                .chargingPlugType == "AC Type 1"
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

    /// BMW may add DC plug types; an unknown value is shown rather than dropped.
    @Test func passesThroughUnknownPlugTypes() {
        #expect(
            state([Descriptor.chargingMethod: TelematicValue(raw: .string("DC_CCS"))])
                .chargingPlugType == "Dc Ccs"
        )
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
