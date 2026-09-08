import Foundation
import Observation

/// Why we stopped being able to hear from the car.
public enum CoverageGapCause: String, Codable, Sendable {
    case sleep
    case network
    case disconnected
    /// The app was not running at all.
    case notRunning

    public var reason: String {
        switch self {
        case .sleep: return "asleep"
        case .network: return "offline"
        case .disconnected: return "disconnected"
        case .notRunning: return "not running"
        }
    }
}

/// A stretch of time during which the car could have changed without us knowing.
public struct CoverageGap: Codable, Equatable, Sendable {
    public let began: Date
    public let ended: Date
    public let cause: CoverageGapCause

    public init(began: Date, ended: Date, cause: CoverageGapCause) {
        self.began = began
        self.ended = ended
        self.cause = cause
    }

    public var duration: TimeInterval { max(0, ended.timeIntervalSince(began)) }

    /// Compact enough for a status chip: "8h", "45m".
    public var shortDuration: String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

/// How much to trust a reading, given whether we were listening when it was taken.
public enum Confidence: Equatable, Sendable {
    /// Reported while we were listening, so anything that happened since would have
    /// reached us. This is as current as the stream can make it.
    case confirmed
    /// Reported before a hole in our listening. Still the last thing the car said, but
    /// it may have been superseded by something we never received.
    case unconfirmed
}

/// Tracks when the app was actually in a position to hear from the car.
///
/// **The problem this exists for.** MQTT is push-only. Nothing published while the Mac
/// is asleep, off the network, or shut down is delivered again unless BMW's broker
/// queued it — and even a queue has limits. So "we have heard nothing" carries two
/// completely different meanings: the car has nothing to say, or we were not listening.
/// Without separating them the panel shows a confident green "Live" over data that
/// stopped being trustworthy hours ago.
///
/// `coverageStart` is the moment the current unbroken listening window began. Any reading
/// stamped at or after it is `confirmed`: we were present, so a change would have
/// arrived. Anything older sits on the far side of a gap and is `unconfirmed`.
@MainActor
@Observable
public final class CoverageTracker {
    /// The beginning of the current unbroken listening window.
    public private(set) var coverageStart: Date
    /// The most recent hole, kept until fresh data supersedes it.
    public private(set) var lastGap: CoverageGap?
    public private(set) var isListening = false

    /// Set while a gap is open, i.e. we know we are not listening.
    private var gapBegan: Date?
    private var gapCause: CoverageGapCause?
    private let store: CoverageStore

    /// - Parameter now: where the current coverage window starts. Only a preview passes
    ///   anything but the default; the real app inherits it from the previous run.
    public init(store: CoverageStore = CoverageStore(), now: Date = Date()) {
        self.store = store
        self.coverageStart = now
    }

    /// Picks up where the previous run left off.
    ///
    /// A quit and relaunch is a hole like any other, but only if it lasted: restarting the
    /// app takes seconds, and treating that as a hole would mark every cached reading
    /// unconfirmed the moment the app opened. So a short break inherits the previous run's
    /// `coverageStart` and knowledge stays continuous; a long one becomes a gap.
    ///
    /// Deliberately not derived from the cached state's `savedAt`: that only advances when
    /// the car reports, so a quiet evening would look like a hole when the app was
    /// listening the whole time.
    public func seedFromPreviousRun(now: Date = Date()) {
        guard let previous = store.load() else { return }
        let elapsed = now.timeIntervalSince(previous.listeningUntil)
        guard elapsed > CoverageStore.heartbeat * 2 else {
            coverageStart = previous.coverageStart
            return
        }
        lastGap = CoverageGap(began: previous.listeningUntil, ended: now, cause: .notRunning)
        coverageStart = now
    }

    /// How long the current hole has been open, or `nil` when we are listening.
    public func openGapDuration(now: Date = Date()) -> TimeInterval? {
        gapBegan.map { now.timeIntervalSince($0) }
    }

    /// The stream is connected again.
    ///
    /// - Parameter gapCovered: whether the broker held our session across the hole. When
    ///   it did, our knowledge is continuous even though our connection was not — anything
    ///   published in the meantime was queued and has just been delivered, and a gap in
    ///   which the car published nothing had nothing to deliver. So `coverageStart` stays
    ///   where it was and no gap is recorded. When it did not, everything older than this
    ///   moment becomes unconfirmed.
    public func beginListening(at now: Date = Date(), gapCovered: Bool = false) {
        if let gapBegan {
            let gap = CoverageGap(began: gapBegan, ended: now, cause: gapCause ?? .disconnected)
            self.gapBegan = nil
            gapCause = nil
            if gapCovered {
                lastGap = nil
            } else {
                lastGap = gap
                coverageStart = now
            }
        }
        isListening = true
        store.record(coverageStart: coverageStart, listeningUntil: now)
    }

    /// We can no longer hear the car. The first cause wins: a sleep that then drops the
    /// network is still one hole, and it started when the Mac went to sleep.
    public func endListening(cause: CoverageGapCause, at now: Date = Date()) {
        isListening = false
        guard gapBegan == nil else { return }
        gapBegan = now
        gapCause = cause
    }

    /// Keeps the on-disk heartbeat current so the *next* launch can size the hole this
    /// run leaves behind.
    public func heartbeat(at now: Date = Date()) {
        guard isListening else { return }
        store.record(coverageStart: coverageStart, listeningUntil: now)
    }

    /// Whether a reading taken at `timestamp` could have been superseded without us
    /// hearing about it.
    public func confidence(of timestamp: Date?) -> Confidence {
        guard let timestamp else { return .unconfirmed }
        return timestamp >= coverageStart ? .confirmed : .unconfirmed
    }

    /// A gap worth telling the user about: long enough to matter, and not yet answered by
    /// fresher data.
    public func unresolvedGap(minimum: TimeInterval = 10 * 60) -> CoverageGap? {
        guard let lastGap, lastGap.duration >= minimum else { return nil }
        return lastGap
    }

    /// Called once data covering the gap has arrived — a replayed backlog, a snapshot, or
    /// simply a fresh reading. The hole is now answered.
    public func resolveGap() { lastGap = nil }
}

/// The heartbeat file, which is how a launch learns how long the last run has been over.
public struct CoverageStore: Sendable {
    /// How often the heartbeat is written. The gap threshold is twice this, so an
    /// ordinary write cadence never registers as a hole.
    public static let heartbeat: TimeInterval = 60

    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("coverage.json")
    }

    private init(ephemeral: Void) { url = nil }

    /// Reads and writes nothing. Previews and `--cli render` build a real `AppModel`, and
    /// without this they would stamp the running app's heartbeat with a made-up window.
    public static let ephemeral = CoverageStore(ephemeral: ())

    /// Both ends matter: `listeningUntil` sizes the hole this run leaves behind, and
    /// `coverageStart` is what a quick relaunch inherits so it does not throw away a
    /// perfectly good window of coverage.
    public struct Record: Codable, Equatable, Sendable {
        public var coverageStart: Date
        public var listeningUntil: Date

        public init(coverageStart: Date, listeningUntil: Date) {
            self.coverageStart = coverageStart
            self.listeningUntil = listeningUntil
        }
    }

    public func load() -> Record? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func record(coverageStart: Date, listeningUntil: Date) {
        guard let url else { return }
        let record = Record(coverageStart: coverageStart, listeningUntil: listeningUntil)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? AppPaths.writePrivate(data, to: url)
    }
}
