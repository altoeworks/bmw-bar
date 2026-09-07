import Foundation
import Testing
@testable import BMWBarKit

@Suite("Stream message decoding")
struct StreamMessageTests {
    private func decode(_ json: String) throws -> StreamMessage {
        try JSONDecoder().decode(StreamMessage.self, from: Data(json.utf8))
    }

    /// A real-shaped payload: envelope plus a sparse `data` map of descriptors.
    @Test func decodesRealPayloadShape() throws {
        let message = try decode("""
        {
          "vin": "WBY71HH0X0CW00000",
          "entityId": "41c477fd-5714-4a2c-af0b-d1d7fbf0addf",
          "timestamp": "2026-09-07T09:54:56.276Z",
          "data": {
            "vehicle.powertrain.electric.battery.stateOfCharge.displayed":
              { "timestamp": "2026-09-07T09:54:55Z", "value": 72, "unit": "%" },
            "vehicle.drivetrain.electricEngine.charging.status":
              { "timestamp": "2026-09-07T09:54:55Z", "value": "CHARGING" }
          }
        }
        """)

        #expect(message.vin == "WBY71HH0X0CW00000")
        #expect(message.entityId == "41c477fd-5714-4a2c-af0b-d1d7fbf0addf")
        #expect(message.sentAt != nil)
        #expect(message.data.count == 2)
        #expect(message.data[Descriptor.socDisplayed]?.doubleValue == 72)
        #expect(message.data[Descriptor.chargingStatus]?.stringValue == "CHARGING")
    }

    /// Applying a stream message must update exactly the descriptors it carries.
    @Test func mergesIntoVehicleState() throws {
        let state = VehicleState()
        state.merge([
            Descriptor.socDisplayed: TelematicValue(
                raw: .number(50),
                timestamp: Date(timeIntervalSince1970: 0)
            ),
            Descriptor.electricRange: TelematicValue(
                raw: .number(300),
                timestamp: Date(timeIntervalSince1970: 0)
            ),
        ])

        let message = try decode("""
        {"vin":"X","data":{
          "vehicle.powertrain.electric.battery.stateOfCharge.displayed":
            {"timestamp":"2026-09-07T09:54:55Z","value":73,"unit":"%"},
          "vehicle.powertrain.electric.battery.charging.power":
            {"timestamp":"2026-09-07T09:54:55Z","value":11.2,"unit":"kW"}
        }}
        """)
        state.merge(message.data)

        #expect(state.chargePercent == 73)
        #expect(state.chargingPowerKW == 11.2)
        // Untouched by this message, so it must survive.
        #expect(state.electricRangeKm == 300)
    }

    /// BMW keeps adding descriptors; unknown ids must not break decoding.
    @Test func keepsUnknownDescriptors() throws {
        let message = try decode("""
        {"data":{"vehicle.some.future.descriptor":{"value":42,"unit":"x"}}}
        """)
        #expect(message.data["vehicle.some.future.descriptor"]?.doubleValue == 42)
    }

    @Test func toleratesEmptyAndEnvelopeOnlyPayloads() throws {
        #expect(try decode(#"{"vin":"X"}"#).data.isEmpty)
        #expect(try decode("{}").data.isEmpty)
    }
}

@Suite("Stream status reporting")
struct StreamStatusTests {
    /// The one-connection-per-account rule needs its own message, not "auth failed".
    @Test func refusalNamesTheLikelyCause() {
        let heldElsewhere = CarDataStream.Status.refused(
            heldElsewhere: true,
            reason: "notAuthorized"
        )
        #expect(heldElsewhere.summary.contains("another client"))
        #expect(!heldElsewhere.isConnected)

        let badCredentials = CarDataStream.Status.refused(
            heldElsewhere: false,
            reason: "badUsernameOrPassword"
        )
        #expect(badCredentials.summary.contains("badUsernameOrPassword"))
    }

    @Test func connectedIsTheOnlyLiveState() {
        #expect(CarDataStream.Status.connected.isConnected)
        #expect(!CarDataStream.Status.connecting.isConnected)
        #expect(!CarDataStream.Status.idle.isConnected)
        #expect(!CarDataStream.Status.disconnected(nil).isConnected)
    }

    /// Keep-alive must stay under BMW's 60 s idle cutoff.
    @Test func keepAliveIsInsideBMWsIdleTimeout() {
        #expect(CarDataStream.keepAlive < 60)
    }
}
