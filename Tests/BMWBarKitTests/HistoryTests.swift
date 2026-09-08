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

@Suite("Session noise filtering")
struct SessionNoiseTests {
    private func sample(_ soc: Double, _ status: String, second: Double) -> Sample {
        Sample(
            at: Date(timeIntervalSince1970: second),
            soc: soc,
            powerKW: 11,
            status: status,
            plugged: true
        )
    }

    /// A charging status that flips within the same second leaves a zero-length
    /// "session" that reads like a failed charge. It is one sample, not an event.
    @Test func dropsZeroLengthBlips() {
        let samples = [
            sample(66, "CHARGINGACTIVE", second: 0),
            sample(66, "NOCHARGING", second: 0),
        ]
        #expect(ChargingSessionBuilder.sessions(from: samples).isEmpty)
    }

    @Test func dropsSessionsUnderAMinute() {
        let samples = [
            sample(66, "CHARGINGACTIVE", second: 0),
            sample(66, "NOCHARGING", second: 30),
        ]
        #expect(ChargingSessionBuilder.sessions(from: samples).isEmpty)
    }

    /// Anything long enough to be a real charge still comes through untouched.
    @Test func keepsGenuineSessions() {
        let samples = [
            sample(60, "CHARGINGACTIVE", second: 0),
            sample(66, "CHARGINGENDED", second: 3600),
        ]
        let sessions = ChargingSessionBuilder.sessions(from: samples)
        #expect(sessions.count == 1)
        #expect(sessions[0].socGained == 6)
    }
}

@Suite("In-progress sessions")
struct InProgressSessionTests {
    private func sample(_ soc: Double, _ status: String, minute: Double) -> Sample {
        Sample(
            at: Date(timeIntervalSince1970: minute * 60),
            soc: soc,
            powerKW: 10.5,
            status: status,
            plugged: true
        )
    }

    /// A charge still running has no terminating sample. It must not be styled as a
    /// failure just because it hasn't finished.
    @Test func runningChargeIsNeitherCompleteNorFailed() throws {
        let samples = [
            sample(64, "CHARGINGACTIVE", minute: 0),
            sample(69, "CHARGINGACTIVE", minute: 22),
        ]
        let session = try #require(ChargingSessionBuilder.sessions(from: samples).first)
        #expect(session.isInProgress)
        #expect(!session.completedNormally)
    }

    @Test func finishedChargeIsNotInProgress() throws {
        let samples = [
            sample(64, "CHARGINGACTIVE", minute: 0),
            sample(80, "CHARGINGENDED", minute: 90),
        ]
        let session = try #require(ChargingSessionBuilder.sessions(from: samples).first)
        #expect(!session.isInProgress)
        #expect(session.completedNormally)
    }
}

@Suite("In-memory sample window")
struct SampleWindowTests {
    private func samples(_ count: Int) -> [Sample] {
        (0..<count).map {
            Sample(
                at: Date(timeIntervalSince1970: Double($0)),
                soc: 50,
                powerKW: nil,
                status: "NOCHARGING",
                plugged: false
            )
        }
    }

    /// The on-disk log keeps 90 days; the in-memory copy must stay bounded regardless,
    /// since it is rebuilt on the main actor as messages arrive.
    @Test func trimsToTheWindow() {
        let trimmed = AppModel.trimmed(samples(AppModel.samplesKeptInMemory + 500))
        #expect(trimmed.count == AppModel.samplesKeptInMemory)
    }

    /// Trimming keeps the *newest* samples — the sparkline and recent sessions both
    /// look at the recent end.
    @Test func keepsTheNewestSamples() {
        let trimmed = AppModel.trimmed(samples(AppModel.samplesKeptInMemory + 10))
        #expect(trimmed.last?.at == Date(timeIntervalSince1970: Double(AppModel.samplesKeptInMemory + 9)))
    }

    @Test func leavesSmallLogsAlone() {
        let few = samples(12)
        #expect(AppModel.trimmed(few).count == 12)
    }

    /// 5000 samples is far more than the 24 h sparkline or recent sessions need, while
    /// still being small in memory.
    @Test func windowComfortablyCoversTheSparkline() {
        #expect(AppModel.samplesKeptInMemory >= 1_000)
    }
}
