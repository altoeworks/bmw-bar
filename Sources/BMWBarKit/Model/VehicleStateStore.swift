import Foundation

/// Caches the last known vehicle state on disk.
///
/// BMW allows 50 REST calls a day and explicitly points at streaming for anything
/// frequent. Without a cache every launch spends one call just to have something to
/// show before the car next reports. With it, a normal launch costs **zero** calls:
/// the panel renders the last known values immediately (labelled with their age) and
/// the stream corrects them as soon as the car says anything.
public struct VehicleStateStore {
    private var url: URL { AppPaths.supportDirectory.appendingPathComponent("state.json") }

    struct Persisted: Codable {
        var values: [String: TelematicValue]
        var savedAt: Date
    }

    public init() {}

    public func load() -> (values: [String: TelematicValue], savedAt: Date)? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data),
              !decoded.values.isEmpty
        else { return nil }
        return (decoded.values, decoded.savedAt)
    }

    public func save(_ values: [String: TelematicValue]) {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(
                  Persisted(values: values, savedAt: Date())
              )
        else { return }
        try? AppPaths.writePrivate(data, to: url)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
