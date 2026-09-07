import Foundation
import Testing
@testable import BMWBarKit

@Suite("Telematic value coercion")
struct TelematicValueTests {
    private func decode(_ json: String) throws -> TelematicValue {
        try JSONDecoder().decode(TelematicValue.self, from: Data(json.utf8))
    }

    /// The stream sends real JSON numbers.
    @Test func decodesNumericValueFromStream() throws {
        let value = try decode(#"{"value":72.5,"unit":"%","timestamp":"2026-09-07T10:11:12Z"}"#)
        #expect(value.doubleValue == 72.5)
        #expect(value.intValue == 73)
        #expect(value.unit == "%")
        #expect(value.timestamp == TelematicValue.parseTimestamp("2026-09-07T10:11:12Z"))
    }

    /// The REST API declares every value as a string, including numbers.
    @Test func decodesNumericValueSentAsString() throws {
        let value = try decode(#"{"value":"72","unit":"%"}"#)
        #expect(value.doubleValue == 72)
        #expect(value.stringValue == "72")
    }

    @Test func decodesBooleans() throws {
        #expect(try decode(#"{"value":true}"#).boolValue == true)
        #expect(try decode(#"{"value":"false"}"#).boolValue == false)
        #expect(try decode(#"{"value":"YES"}"#).boolValue == true)
    }

    @Test func decodesEnumStrings() throws {
        let value = try decode(#"{"value":"CHARGING"}"#)
        #expect(value.stringValue == "CHARGING")
        #expect(value.doubleValue == nil)
    }

    @Test func toleratesMissingUnitAndTimestamp() throws {
        let value = try decode(#"{"value":1}"#)
        #expect(value.unit == nil)
        #expect(value.timestamp == nil)
    }

    /// BMW mixes both ISO 8601 precisions inside a single payload.
    @Test func parsesBothTimestampPrecisions() {
        #expect(TelematicValue.parseTimestamp("2026-09-07T09:54:55Z") != nil)
        #expect(TelematicValue.parseTimestamp("2026-09-07T09:54:56.276Z") != nil)
        #expect(TelematicValue.parseTimestamp("not a date") == nil)
    }
}

@Suite("Charging status")
struct ChargingStatusTests {
    @Test func mapsKnownStates() {
        #expect(ChargingStatus(raw: "CHARGING") == .charging)
        #expect(ChargingStatus(raw: "charging") == .charging)
        #expect(ChargingStatus(raw: "NOT_CHARGING") == .notCharging)
        #expect(ChargingStatus(raw: "COMPLETE") == .complete)
    }

    /// An unrecognised state must survive rather than collapse to "unknown".
    @Test func preservesUnknownStates() {
        let status = ChargingStatus(raw: "SOME_NEW_STATE")
        #expect(status == .unknown("SOME_NEW_STATE"))
        #expect(!status.isActivelyCharging)
    }
}

@Suite("Vehicle state merging")
struct VehicleStateTests {
    private func value(_ raw: Double, at seconds: TimeInterval, unit: String? = nil) -> TelematicValue {
        TelematicValue(
            raw: .number(raw),
            unit: unit,
            timestamp: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func mergeAppliesNewerReadings() {
        let state = VehicleState()
        state.merge([Descriptor.socDisplayed: value(50, at: 100)])
        state.merge([Descriptor.socDisplayed: value(55, at: 200)])
        #expect(state.chargePercent == 55)
    }

    /// Messages can arrive out of order; an older reading must not win.
    @Test func mergeIgnoresStaleReadings() {
        let state = VehicleState()
        state.merge([Descriptor.socDisplayed: value(55, at: 200)])
        state.merge([Descriptor.socDisplayed: value(50, at: 100)])
        #expect(state.chargePercent == 55)
    }

    /// The stream sends only what changed, so untouched descriptors must persist.
    @Test func mergeIsSparseAndKeepsUntouchedValues() {
        let state = VehicleState()
        state.merge([
            Descriptor.socDisplayed: value(50, at: 100),
            Descriptor.electricRange: value(300, at: 100),
        ])
        state.merge([Descriptor.socDisplayed: value(51, at: 200)])
        #expect(state.chargePercent == 51)
        #expect(state.electricRangeKm == 300)
    }

    @Test func chargePercentFallsBackThroughDescriptors() {
        let state = VehicleState()
        state.merge([Descriptor.socHeader: value(64, at: 100)])
        #expect(state.chargePercent == 64)

        // The displayed value is what the cluster shows, so it wins when present.
        state.merge([Descriptor.socDisplayed: value(66, at: 100)])
        #expect(state.chargePercent == 66)
    }

    @Test func normalisesChargingPowerToKilowatts() {
        let state = VehicleState()
        state.merge([Descriptor.chargingPower: value(11000, at: 100, unit: "W")])
        #expect(state.chargingPowerKW == 11)

        let other = VehicleState()
        other.merge([Descriptor.chargingPower: value(11, at: 100, unit: "kW")])
        #expect(other.chargingPowerKW == 11)
    }

    @Test func exposesChargeLimitAsReadOnlyValue() {
        let state = VehicleState()
        state.merge([Descriptor.socTarget: value(80, at: 100, unit: "%")])
        #expect(state.chargeLimitPercent == 80)
    }

    @Test func tracksNewestReadingTimestamp() {
        let state = VehicleState()
        state.merge([
            Descriptor.socDisplayed: value(50, at: 100),
            Descriptor.electricRange: value(300, at: 500),
        ])
        #expect(state.newestReadingTimestamp == Date(timeIntervalSince1970: 500))
    }

    @Test func isChargingReflectsStatus() {
        let state = VehicleState()
        state.merge([Descriptor.chargingStatus: TelematicValue(raw: .string("CHARGING"))])
        #expect(state.isCharging)
        state.merge([Descriptor.chargingStatus: TelematicValue(raw: .string("COMPLETE"))])
        #expect(!state.isCharging)
    }
}

@Suite("API quota")
struct QuotaTrackerTests {
    private func tracker() -> QuotaTracker {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-\(UUID().uuidString).json")
        return QuotaTracker(url: url)
    }

    @Test func countsCallsAgainstTheDailyLimit() async throws {
        let quota = tracker()
        try await quota.consume(essential: true)
        try await quota.consume(essential: true)

        let snapshot = await quota.snapshot()
        #expect(snapshot.used == 2)
        #expect(snapshot.remaining == QuotaTracker.dailyLimit - 2)
    }

    /// Optional calls stop at the reserve so essential ones can still get through.
    @Test func optionalCallsStopAtTheReserve() async throws {
        let quota = tracker()
        let usableByOptional = QuotaTracker.dailyLimit - QuotaTracker.reserve
        for _ in 0..<usableByOptional { try await quota.consume(essential: false) }

        await #expect(throws: QuotaTracker.Error.self) {
            try await quota.consume(essential: false)
        }
        // Essential calls may still use the reserve.
        try await quota.consume(essential: true)
    }

    @Test func essentialCallsThrowOnlyWhenFullyExhausted() async throws {
        let quota = tracker()
        for _ in 0..<QuotaTracker.dailyLimit { try await quota.consume(essential: true) }

        await #expect(throws: QuotaTracker.Error.self) {
            try await quota.consume(essential: true)
        }
        #expect(await quota.snapshot().isExhausted)
    }

    @Test func persistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-\(UUID().uuidString).json")
        let first = QuotaTracker(url: url)
        try await first.consume(essential: true)

        let second = QuotaTracker(url: url)
        #expect(await second.snapshot().used == 1)
    }

    /// The budget resets at midnight UTC, not local midnight.
    @Test func resetsAtUTCMidnight() {
        let noonUTC = Date(timeIntervalSince1970: 1_788_782_400)  // 2026-09-07T12:00:00Z
        #expect(QuotaTracker.utcDay(noonUTC) == "2026-09-07")

        let reset = QuotaTracker.nextUTCMidnight(after: noonUTC)
        #expect(QuotaTracker.utcDay(reset) == "2026-09-08")
        #expect(reset.timeIntervalSince(noonUTC) == 12 * 3600)
    }
}
