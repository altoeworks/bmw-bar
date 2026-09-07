import Foundation

public struct QuotaSnapshot: Equatable, Sendable {
    public let used: Int
    public let limit: Int
    public let resetsAt: Date

    public var remaining: Int { max(0, limit - used) }
    public var isExhausted: Bool { remaining == 0 }
}

/// BMW allows **50 REST calls per account per day**, shared across all vehicles and
/// reset at midnight UTC. Blowing through it locks the app out of the API until the
/// next day, so every call goes through here.
///
/// Streaming is not metered — it is the intended way to get frequent updates, and the
/// REST budget is reserved for what streaming cannot supply (vehicle list, model name,
/// container setup, one snapshot at launch).
public actor QuotaTracker {
    public static let dailyLimit = 50
    /// Calls held back for essential work, so a burst of optional refreshes can never
    /// starve the next launch's snapshot.
    public static let reserve = 5

    public enum Error: Swift.Error, CustomStringConvertible {
        case exhausted(resetsAt: Date)
        case reserved(remaining: Int)

        public var description: String {
            switch self {
            case .exhausted(let resetsAt):
                return "BMW's 50 calls/day budget is spent. It resets at "
                    + "\(ISO8601DateFormatter().string(from: resetsAt))."
            case .reserved(let remaining):
                return "Only \(remaining) API calls left today; holding them back for "
                    + "essential requests. Live data continues over the stream."
            }
        }
    }

    private struct State: Codable {
        var day: String
        var used: Int
    }

    private var state: State
    private let url: URL

    public init(url: URL = AppPaths.quotaFile) {
        self.url = url
        let stored = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        self.state = stored ?? State(day: Self.utcDay(), used: 0)
    }

    /// Records one API call, or throws if the budget will not allow it.
    /// - Parameter essential: essential calls may dip into the reserve.
    public func consume(essential: Bool) throws {
        rolloverIfNeeded()

        let remaining = Self.dailyLimit - state.used
        if remaining <= 0 { throw Error.exhausted(resetsAt: Self.nextUTCMidnight()) }
        if !essential, remaining <= Self.reserve { throw Error.reserved(remaining: remaining) }

        state.used += 1
        persist()
    }

    /// Marks the budget spent because BMW said so (`CU-429`).
    ///
    /// The local counter is only a mirror — BMW exposes no rate-limit headers and no
    /// quota endpoint — so it can drift if another client shares the account. BMW's
    /// own refusal is authoritative, so trust it over the count.
    public func markExhaustedByServer() {
        rolloverIfNeeded()
        state.used = max(state.used, Self.dailyLimit)
        persist()
    }

    public func snapshot() -> QuotaSnapshot {
        rolloverIfNeeded()
        return QuotaSnapshot(
            used: state.used,
            limit: Self.dailyLimit,
            resetsAt: Self.nextUTCMidnight()
        )
    }

    private func rolloverIfNeeded() {
        let today = Self.utcDay()
        guard state.day != today else { return }
        state = State(day: today, used: 0)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? AppPaths.writePrivate(data, to: url)
    }

    // MARK: - UTC day arithmetic

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func utcDay(_ date: Date = Date()) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func nextUTCMidnight(after date: Date = Date()) -> Date {
        let calendar = utcCalendar
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    }
}
