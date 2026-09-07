import Foundation

/// One recorded moment of the things that change over time.
public struct Sample: Codable, Equatable, Sendable {
    public let at: Date
    public let soc: Double?
    /// Charging power in kW.
    public let powerKW: Double?
    /// Raw BMW status string, kept verbatim so old logs survive vocabulary changes.
    public let status: String?
    public let plugged: Bool?

    public init(at: Date, soc: Double?, powerKW: Double?, status: String?, plugged: Bool?) {
        self.at = at
        self.soc = soc
        self.powerKW = powerKW
        self.status = status
        self.plugged = plugged
    }

    public init(_ state: VehicleState, at: Date = Date()) {
        self.at = at
        soc = state.chargePercent
        powerKW = state.chargingPowerKW
        status = state[Descriptor.chargingStatus]?.stringValue
            ?? state[Descriptor.chargingHVStatus]?.stringValue
        plugged = state.isPluggedIn
    }

    public var chargingStatus: ChargingStatus? { status.map(ChargingStatus.init(raw:)) }
    public var isCharging: Bool { chargingStatus?.isActivelyCharging ?? false }

    /// Whether this differs from `other` in a way worth writing a line for. A parked
    /// car repeats the same values indefinitely, and logging those would grow the file
    /// for nothing.
    public func isMeaningfullyDifferent(from other: Sample) -> Bool {
        if status != other.status || plugged != other.plugged { return true }
        if let a = soc, let b = other.soc, abs(a - b) >= 0.5 { return true }
        if (soc == nil) != (other.soc == nil) { return true }
        // Power moves constantly while charging; only record real steps.
        if let a = powerKW, let b = other.powerKW, abs(a - b) >= 0.2 { return true }
        if (powerKW == nil) != (other.powerKW == nil) { return true }
        return false
    }
}

/// Append-only history of the car, recorded from the stream.
///
/// This is what makes BMW's REST `chargingHistory` endpoint unnecessary: the stream
/// already carries everything, at higher resolution, for free. Storing it locally means
/// unlimited retention without ever spending one of the 50 daily calls.
///
/// Written as JSON Lines so appending is a single `write` with no read-modify-write of
/// the whole file.
public final class SampleLog {
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let url: URL
    private var lastRecorded: Sample?
    /// Guards `lastRecorded` and file appends.
    private let queue = DispatchQueue(label: "com.ohoefenstock.bmw-bar.samplelog")

    public init(url: URL? = nil) {
        self.url = url
            ?? AppPaths.supportDirectory
                .appendingPathComponent("history", isDirectory: true)
                .appendingPathComponent("samples.jsonl")
    }

    /// Records a sample if it says something new.
    /// - Returns: whether a line was written.
    @discardableResult
    public func record(_ sample: Sample) -> Bool {
        queue.sync {
            if let last = lastRecorded, !sample.isMeaningfullyDifferent(from: last) {
                return false
            }
            lastRecorded = sample
            append(sample)
            return true
        }
    }

    public func load() -> [Sample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Sample.self, from: Data(line.utf8))
        }
    }

    /// Drops samples older than `retention`. Cheap enough to run at launch.
    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let kept = load().filter { $0.at >= cutoff }
        rewrite(kept)
    }

    public func clear() {
        queue.sync {
            lastRecorded = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Storage

    private func append(_ sample: Sample) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        var line = data
        line.append(0x0A)  // newline

        ensureFile()
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func rewrite(_ samples: [Sample]) {
        let encoder = JSONEncoder()
        let body = samples.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        let data = Data((body.isEmpty ? "" : body + "\n").utf8)
        try? AppPaths.writePrivate(data, to: url)
    }

    private func ensureFile() {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? AppPaths.writePrivate(Data(), to: url)
        }
    }
}
