import Foundation
import Testing
@testable import BMWBarKit

/// BMW rejects a container containing an unknown or deprecated descriptor with
/// `CU-402 Telematic key is invalid` — and it fails the *whole* request, so a single
/// bad id makes the app unusable. These tests pin every id the app subscribes to
/// against BMW's published catalogue.
///
/// Refresh the fixture with `Scripts/fetch-catalogue.sh` when BMW extends it.
@Suite("Descriptor catalogue")
struct DescriptorCatalogueTests {
    static let catalogue: Set<String> = {
        guard let url = Bundle.module.url(
            forResource: "catalogue-ids",
            withExtension: "json",
            subdirectory: "Fixtures"
        ),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(CatalogueFixture.self, from: data)
        else { return [] }
        return Set(decoded.ids)
    }()

    private struct CatalogueFixture: Decodable {
        let ids: [String]
        let count: Int
    }

    @Test func fixtureLoads() {
        #expect(Self.catalogue.count > 200, "catalogue fixture missing or truncated")
    }

    /// The regression test for the CU-402 failure: `vehicle.travelledDistance` and
    /// `vehicle.drivetrain.electricEngine.charging.level` were both invented, and BMW
    /// refused the whole container because of them.
    @Test(arguments: Descriptor.all)
    func everySubscribedDescriptorExistsInBMWsCatalogue(id: String) {
        #expect(Self.catalogue.contains(id), "\(id) is not a valid BMW descriptor")
    }

    @Test func descriptorListHasNoDuplicates() {
        #expect(Set(Descriptor.all).count == Descriptor.all.count)
    }

    @Test func everyDescriptorHasAReadableLabel() {
        for id in Descriptor.all {
            #expect(Descriptor.label(for: id) != id, "no label for \(id)")
        }
    }

    /// The odometer id really does repeat the `vehicle` segment; it looks like a typo
    /// and was "corrected" once already.
    @Test func odometerKeepsBMWsDoubledNamespace() {
        #expect(Descriptor.mileage == "vehicle.vehicle.travelledDistance")
        #expect(!Self.catalogue.contains("vehicle.travelledDistance"))
    }
}

@Suite("Charging status vocabularies")
struct ChargingStatusVocabularyTests {
    /// `vehicle.drivetrain.electricEngine.charging.status`
    @Test func mapsTheStatusDescriptorVocabulary() {
        #expect(ChargingStatus(raw: "CHARGINGACTIVE") == .charging)
        #expect(ChargingStatus(raw: "NOCHARGING") == .notCharging)
        #expect(ChargingStatus(raw: "INITIALIZATION") == .initialising)
        #expect(ChargingStatus(raw: "CHARGINGPAUSED") == .paused)
        #expect(ChargingStatus(raw: "CHARGINGINTERRUPTED") == .paused)
        #expect(ChargingStatus(raw: "CHARGINGDISRUPTED") == .paused)
        #expect(ChargingStatus(raw: "CHARGINGENDED") == .ended)
        #expect(ChargingStatus(raw: "CHARGINGERROR") == .error)
    }

    /// `vehicle.drivetrain.electricEngine.charging.hvStatus` — a different vocabulary
    /// for the same concept.
    @Test func mapsTheHVStatusDescriptorVocabulary() {
        #expect(ChargingStatus(raw: "CHARGING") == .charging)
        #expect(ChargingStatus(raw: "NOT_CHARGING") == .notCharging)
        #expect(ChargingStatus(raw: "WAITING_FOR_CHARGING") == .waiting)
        #expect(ChargingStatus(raw: "FINISHED_FULLY_CHARGED") == .complete)
        #expect(ChargingStatus(raw: "FINISHED_NOT_FULL") == .ended)
        #expect(ChargingStatus(raw: "ERROR") == .error)
    }

    @Test func placeholderValuesAreNotTreatedAsInformative() {
        #expect(!ChargingStatus(raw: "UNKNOWN").isInformative)
        #expect(!ChargingStatus(raw: "INVALID").isInformative)
        #expect(ChargingStatus(raw: "CHARGINGACTIVE").isInformative)
        // A genuinely new state is unknown to us but still worth showing.
        #expect(ChargingStatus(raw: "SOME_NEW_STATE").isInformative)
    }

    /// Only `CHARGINGACTIVE`/`CHARGING` mean current is flowing.
    @Test func onlyActiveStatesCountAsCharging() {
        #expect(ChargingStatus(raw: "CHARGINGACTIVE").isActivelyCharging)
        #expect(ChargingStatus(raw: "CHARGING").isActivelyCharging)
        for idle in ["NOCHARGING", "CHARGINGENDED", "CHARGINGPAUSED", "FINISHED_FULLY_CHARGED"] {
            #expect(!ChargingStatus(raw: idle).isActivelyCharging, "\(idle) should not count")
        }
    }
}

@Suite("Vehicle state against real BMW semantics")
struct VehicleStateSemanticsTests {
    private func state(_ pairs: [String: TelematicValue]) -> VehicleState {
        let state = VehicleState()
        state.merge(pairs)
        return state
    }

    /// The status descriptor can read UNKNOWN while hvStatus is meaningful; prefer
    /// whichever actually says something.
    @Test func prefersTheInformativeStatusDescriptor() {
        let s = state([
            Descriptor.chargingStatus: TelematicValue(raw: .string("UNKNOWN")),
            Descriptor.chargingHVStatus: TelematicValue(raw: .string("CHARGING")),
        ])
        #expect(s.chargingStatus == .charging)
        #expect(s.isCharging)
    }

    @Test func fallsBackWhenOnlyOneStatusIsPresent() {
        #expect(
            state([Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGINGACTIVE"))])
                .chargingStatus == .charging
        )
        #expect(
            state([Descriptor.chargingHVStatus: TelematicValue(raw: .string("NOT_CHARGING"))])
                .chargingStatus == .notCharging
        )
    }

    /// BMW declares charging power in watts.
    @Test func readsChargingPowerAsWatts() {
        #expect(
            state([Descriptor.chargingPower: TelematicValue(raw: .number(11000), unit: "W")])
                .chargingPowerKW == 11
        )
        // Unit missing: a large bare number is still watts.
        #expect(
            state([Descriptor.chargingPower: TelematicValue(raw: .number(11000))])
                .chargingPowerKW == 11
        )
    }

    /// `timeRemaining` is capped at 200 min, so long sessions need `timeToFullyCharged`.
    @Test func fallsBackToTimeToFullForLongSessions() {
        #expect(
            state([Descriptor.chargingTimeToFull: TelematicValue(raw: .number(430))])
                .chargingMinutesRemaining == 430
        )
        #expect(
            state([
                Descriptor.chargingTimeRemaining: TelematicValue(raw: .number(45)),
                Descriptor.chargingTimeToFull: TelematicValue(raw: .number(430)),
            ]).chargingMinutesRemaining == 45
        )
    }

    /// The port descriptor's vocabulary is CONNECTED / DISCONNECTED / INVALID / -NA-.
    @Test func readsPlugStateFromThePortVocabulary() {
        #expect(
            state([Descriptor.chargingPortStatus: TelematicValue(raw: .string("CONNECTED"))])
                .isPluggedIn == true
        )
        #expect(
            state([Descriptor.chargingPortStatus: TelematicValue(raw: .string("DISCONNECTED"))])
                .isPluggedIn == false
        )
        // Placeholders must read as unknown, not as "unplugged".
        #expect(
            state([Descriptor.chargingPortStatus: TelematicValue(raw: .string("INVALID"))])
                .isPluggedIn == nil
        )
        #expect(
            state([Descriptor.chargingPortStatus: TelematicValue(raw: .string("-NA-"))])
                .isPluggedIn == nil
        )
    }

    @Test func booleanPlugDescriptorWinsOverThePortStatus() {
        #expect(
            state([
                Descriptor.plugged: TelematicValue(raw: .bool(true)),
                Descriptor.chargingPortStatus: TelematicValue(raw: .string("INVALID")),
            ]).isPluggedIn == true
        )
    }
}
