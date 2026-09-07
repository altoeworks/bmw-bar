import Foundation
import Testing
@testable import BMWBarKit

@Suite("Sample log")
struct SampleLogTests {
    private func temporaryLog() -> SampleLog {
        SampleLog(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("samples-\(UUID().uuidString).jsonl"))
    }

    private func sample(_ soc: Double?, _ power: Double?, _ status: String?, at: TimeInterval)
        -> Sample
    {
        Sample(
            at: Date(timeIntervalSince1970: at),
            soc: soc,
            powerKW: power,
            status: status,
            plugged: true
        )
    }

    /// A parked car repeats the same values forever; logging those would grow the file
    /// for nothing.
    @Test func skipsUnchangedSamples() {
        let log = temporaryLog()
        #expect(log.record(sample(50, 0, "NOCHARGING", at: 0)))
        #expect(!log.record(sample(50, 0, "NOCHARGING", at: 60)))
        #expect(!log.record(sample(50.2, 0, "NOCHARGING", at: 120)))
        #expect(log.load().count == 1)
    }

    @Test func recordsMeaningfulChanges() {
        let log = temporaryLog()
        _ = log.record(sample(50, 0, "NOCHARGING", at: 0))
        #expect(log.record(sample(50, 0, "CHARGINGACTIVE", at: 60)))   // status
        #expect(log.record(sample(51, 0, "CHARGINGACTIVE", at: 120)))  // SoC step
        #expect(log.record(sample(51, 11, "CHARGINGACTIVE", at: 180))) // power step
        #expect(log.load().count == 4)
    }

    @Test func roundTripsThroughDisk() {
        let log = temporaryLog()
        _ = log.record(sample(42, 7.4, "CHARGINGACTIVE", at: 1_000))
        let loaded = log.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].soc == 42)
        #expect(loaded[0].powerKW == 7.4)
        #expect(loaded[0].status == "CHARGINGACTIVE")
        #expect(loaded[0].isCharging)
    }

    @Test func prunesOldSamples() {
        let log = temporaryLog()
        let now = Date(timeIntervalSince1970: 10_000_000)
        _ = log.record(sample(10, 0, "NOCHARGING", at: now.timeIntervalSince1970 - 120 * 24 * 3600))
        _ = log.record(sample(20, 0, "CHARGINGACTIVE", at: now.timeIntervalSince1970 - 3600))
        log.prune(now: now)

        let kept = log.load()
        #expect(kept.count == 1)
        #expect(kept[0].soc == 20)
    }
}

@Suite("Charging session reconstruction")
struct ChargingSessionTests {
    private func sample(_ soc: Double, _ power: Double?, _ status: String, minute: Double) -> Sample {
        Sample(
            at: Date(timeIntervalSince1970: minute * 60),
            soc: soc,
            powerKW: power,
            status: status,
            plugged: true
        )
    }

    @Test func buildsOneSessionFromAChargeCycle() {
        let samples = [
            sample(40, 0, "NOCHARGING", minute: 0),
            sample(40, 11, "CHARGINGACTIVE", minute: 10),
            sample(50, 11, "CHARGINGACTIVE", minute: 40),
            sample(60, 11, "CHARGINGACTIVE", minute: 70),
            sample(60, 0, "CHARGINGENDED", minute: 80),
        ]
        let sessions = ChargingSessionBuilder.sessions(from: samples)

        #expect(sessions.count == 1)
        let session = sessions[0]
        #expect(session.startSoC == 40)
        #expect(session.endSoC == 60)
        #expect(session.socGained == 20)
        #expect(session.peakPowerKW == 11)
        #expect(session.endStatus == .ended)
        #expect(session.completedNormally)
        #expect(session.duration == 70 * 60)
    }

    /// A charge cut short must be distinguishable from one that finished.
    @Test func recordsAnInterruptedSession() {
        let samples = [
            sample(40, 11, "CHARGINGACTIVE", minute: 0),
            sample(45, 11, "CHARGINGACTIVE", minute: 30),
            sample(45, 0, "CHARGINGERROR", minute: 35),
        ]
        let session = ChargingSessionBuilder.sessions(from: samples)[0]
        #expect(session.endStatus == .error)
        #expect(!session.completedNormally)
    }

    @Test func separatesTwoSessions() {
        let samples = [
            sample(40, 11, "CHARGINGACTIVE", minute: 0),
            sample(50, 0, "CHARGINGENDED", minute: 60),
            sample(45, 11, "CHARGINGACTIVE", minute: 600),
            sample(55, 0, "CHARGINGENDED", minute: 660),
        ]
        #expect(ChargingSessionBuilder.sessions(from: samples).count == 2)
    }

    /// An in-progress charge should still show up, ending at the latest sample.
    @Test func includesASessionStillRunning() {
        let samples = [
            sample(40, 11, "CHARGINGACTIVE", minute: 0),
            sample(48, 11, "CHARGINGACTIVE", minute: 45),
        ]
        let sessions = ChargingSessionBuilder.sessions(from: samples)
        #expect(sessions.count == 1)
        #expect(sessions[0].endStatus == nil)
    }

    /// Two hours at a steady 11 kW is 22 kWh — checked by hand.
    @Test func integratesEnergyFromThePowerCurve() throws {
        let samples = [
            sample(40, 11, "CHARGINGACTIVE", minute: 0),
            sample(50, 11, "CHARGINGACTIVE", minute: 60),
            sample(60, 11, "CHARGINGACTIVE", minute: 120),
        ]
        let energy = try #require(ChargingSessionBuilder.energyKWh(from: samples))
        #expect(abs(energy - 22) < 0.01)
    }

    /// Trapezoidal integration must average across a ramp, not take either endpoint.
    @Test func averagesAcrossAPowerRamp() throws {
        // 0 kW rising to 10 kW over one hour = 5 kWh.
        let samples = [
            sample(40, 0, "CHARGINGACTIVE", minute: 0),
            sample(41, 10, "CHARGINGACTIVE", minute: 60),
        ]
        let energy = try #require(ChargingSessionBuilder.energyKWh(from: samples))
        #expect(abs(energy - 5) < 0.01)
    }

    @Test func energyIsNilWithoutEnoughPowerSamples() {
        #expect(ChargingSessionBuilder.energyKWh(from: [
            sample(40, 11, "CHARGINGACTIVE", minute: 0),
        ]) == nil)
    }

    @Test func energyFromSoCDeltaWhenCapacityIsKnown() throws {
        // 20% of a 67 kWh pack.
        let energy = try #require(
            ChargingSessionBuilder.energyKWh(startSoC: 40, endSoC: 60, capacityKWh: 67)
        )
        #expect(abs(energy - 13.4) < 0.01)
        // Unknown capacity means no estimate rather than a wrong one.
        #expect(ChargingSessionBuilder.energyKWh(startSoC: 40, endSoC: 60, capacityKWh: nil) == nil)
    }
}

@Suite("Sparkline")
struct SparklineDataTests {
    private func sample(_ soc: Double, hoursAgo: Double, now: Date) -> Sample {
        Sample(
            at: now.addingTimeInterval(-hoursAgo * 3600),
            soc: soc,
            powerKW: nil,
            status: nil,
            plugged: nil
        )
    }

    private let now = Date(timeIntervalSince1970: 1_788_782_400)

    @Test func normalisesToUnitSquare() {
        let samples = (0..<12).map { sample(Double(40 + $0 * 5), hoursAgo: Double(12 - $0), now: now) }
        let points = SparklineData.points(from: samples, now: now)

        #expect(points.count >= 2)
        #expect(points.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        #expect(points.first?.x == 0)
        #expect(points.last?.x == 1)
    }

    /// A parked car produces a flat line, which is legitimate — not a divide by zero.
    @Test func handlesAFlatSeries() {
        let samples = (0..<6).map { sample(66, hoursAgo: Double($0), now: now) }
        let points = SparklineData.points(from: samples, now: now)
        #expect(points.count >= 2)
        #expect(points.allSatisfy { $0.y == 0.5 })
    }

    @Test func ignoresSamplesOutsideTheWindow() {
        let samples = [
            sample(10, hoursAgo: 48, now: now),  // outside 24 h
            sample(60, hoursAgo: 3, now: now),
            sample(70, hoursAgo: 1, now: now),
        ]
        let range = SparklineData.range(of: samples, now: now)
        #expect(range?.low == 60)
        #expect(range?.high == 70)
    }

    @Test func returnsNothingWithoutEnoughHistory() {
        #expect(SparklineData.points(from: [], now: now).isEmpty)
        #expect(SparklineData.points(from: [sample(50, hoursAgo: 1, now: now)], now: now).isEmpty)
    }
}
