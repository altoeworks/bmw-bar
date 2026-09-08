import Foundation
import Testing

@testable import BMWBarKit

/// A store pointed at a scratch file, so a test never reads or writes the real heartbeat.
private func temporaryStore() -> CoverageStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("coverage-\(UUID().uuidString).json")
    return CoverageStore(url: url)
}

@MainActor
@Suite("Coverage")
struct CoverageTests {
    @Test("A fresh tracker vouches for anything reported since it started")
    func confidenceWhileListening() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)

        #expect(tracker.confidence(of: start.addingTimeInterval(60)) == .confirmed)
        #expect(tracker.confidence(of: start.addingTimeInterval(-60)) == .unconfirmed)
        #expect(tracker.confidence(of: nil) == .unconfirmed)
    }

    @Test("An uncovered gap makes everything older than the reconnect unconfirmed")
    func uncoveredGap() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)

        let beforeSleep = start.addingTimeInterval(60)
        tracker.endListening(cause: .sleep, at: start.addingTimeInterval(120))
        let wake = start.addingTimeInterval(3 * 3600)
        tracker.beginListening(at: wake, gapCovered: false)

        // The reading itself did not change; what changed is that we stopped watching.
        #expect(tracker.confidence(of: beforeSleep) == .unconfirmed)
        #expect(tracker.confidence(of: wake.addingTimeInterval(1)) == .confirmed)

        let gap = try? #require(tracker.lastGap)
        #expect(gap?.cause == .sleep)
        // Date arithmetic is floating point, so compare with a tolerance rather than
        // exactly.
        #expect(abs((gap?.duration ?? 0) - (3 * 3600 - 120)) < 0.001)
    }

    @Test("A gap the broker held our session across leaves knowledge continuous")
    func coveredGap() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)

        let beforeSleep = start.addingTimeInterval(60)
        tracker.endListening(cause: .sleep, at: start.addingTimeInterval(120))
        tracker.beginListening(at: start.addingTimeInterval(3 * 3600), gapCovered: true)

        // Anything published during the gap was queued and has just been replayed, so the
        // old reading is still the current one.
        #expect(tracker.confidence(of: beforeSleep) == .confirmed)
        #expect(tracker.lastGap == nil)
        #expect(tracker.unresolvedGap() == nil)
    }

    @Test("The first cause of a gap wins, so sleep-then-network is one hole")
    func firstCauseWins() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)

        tracker.endListening(cause: .sleep, at: start.addingTimeInterval(10))
        tracker.endListening(cause: .network, at: start.addingTimeInterval(11))
        tracker.endListening(cause: .disconnected, at: start.addingTimeInterval(12))
        tracker.beginListening(at: start.addingTimeInterval(7200))

        #expect(tracker.lastGap?.cause == .sleep)
        #expect(tracker.lastGap?.began == start.addingTimeInterval(10))
    }

    @Test("Short gaps are not worth mentioning")
    func gapThreshold() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)
        tracker.endListening(cause: .disconnected, at: start.addingTimeInterval(10))
        tracker.beginListening(at: start.addingTimeInterval(70))

        #expect(tracker.lastGap != nil)
        #expect(tracker.unresolvedGap(minimum: 10 * 60) == nil)
    }

    @Test("Fresh data answers the gap")
    func resolvingAGap() {
        let start = Date()
        let tracker = CoverageTracker(store: temporaryStore(), now: start)
        tracker.beginListening(at: start)
        tracker.endListening(cause: .sleep, at: start)
        tracker.beginListening(at: start.addingTimeInterval(8 * 3600))

        #expect(tracker.unresolvedGap() != nil)
        tracker.resolveGap()
        #expect(tracker.unresolvedGap() == nil)
    }

    @Test("The heartbeat from a previous run sizes the hole the app left behind")
    func seedingFromPreviousRun() {
        let store = temporaryStore()
        let quitAt = Date().addingTimeInterval(-6 * 3600)
        store.record(coverageStart: quitAt.addingTimeInterval(-3600), listeningUntil: quitAt)

        let tracker = CoverageTracker(store: store)
        tracker.seedFromPreviousRun()

        let gap = tracker.lastGap
        #expect(gap?.cause == .notRunning)
        #expect((gap?.duration ?? 0) > 5.9 * 3600)
    }

    @Test("A relaunch moments after the last heartbeat is not a gap")
    func seedingIgnoresARestart() {
        let store = temporaryStore()
        let windowBegan = Date().addingTimeInterval(-4 * 3600)
        store.record(coverageStart: windowBegan, listeningUntil: Date().addingTimeInterval(-5))

        let tracker = CoverageTracker(store: store)
        tracker.seedFromPreviousRun()

        #expect(tracker.lastGap == nil)
        // A relaunch inherits the previous run's window, so readings from before the
        // restart are still vouched for rather than all going amber at once.
        #expect(tracker.coverageStart == windowBegan)
        #expect(tracker.confidence(of: windowBegan.addingTimeInterval(60)) == .confirmed)
    }

    @Test("A first ever launch has nothing to seed from")
    func seedingWithNoHistory() {
        let tracker = CoverageTracker(store: temporaryStore())
        tracker.seedFromPreviousRun()
        #expect(tracker.lastGap == nil)
    }

    @Test("Gap durations read compactly")
    func shortDuration() {
        let start = Date()
        func gap(_ seconds: TimeInterval) -> CoverageGap {
            CoverageGap(began: start, ended: start.addingTimeInterval(seconds), cause: .sleep)
        }
        #expect(gap(45 * 60).shortDuration == "45m")
        #expect(gap(3 * 3600).shortDuration == "3h")
        #expect(gap(50 * 3600).shortDuration == "2d")
    }
}

@MainActor
@Suite("Backlog")
struct BacklogTests {
    private func message(sentAt: Date?) -> StreamMessage {
        var json = "{\"vin\":\"WBYTESTVIN1234567\",\"data\":{}}"
        if let sentAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            json = "{\"vin\":\"WBYTESTVIN1234567\",\"timestamp\":\"\(formatter.string(from: sentAt))\",\"data\":{}}"
        }
        return try! JSONDecoder().decode(StreamMessage.self, from: Data(json.utf8))
    }

    @Test("A message published before we reconnected is a replay, not news")
    func detectsBacklog() {
        let model = AppModel(previewValues: [:])
        let now = Date()

        #expect(model.isBacklog(message(sentAt: now.addingTimeInterval(-3600)), now: now))
        #expect(model.isBacklog(message(sentAt: now.addingTimeInterval(-150)), now: now))
    }

    @Test("A live message is not treated as backlog")
    func livePassesThrough() {
        let model = AppModel(previewValues: [:])
        let now = Date()

        #expect(!model.isBacklog(message(sentAt: now.addingTimeInterval(-5)), now: now))
        // BMW does not always stamp the envelope; an unstamped message is the car
        // speaking now, not a replay we cannot date.
        #expect(!model.isBacklog(message(sentAt: nil), now: now))
    }
}
