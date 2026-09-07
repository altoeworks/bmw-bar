import Foundation

/// One telematic data point.
///
/// The two transports disagree about types: the REST API declares every `value` as a
/// string, while the MQTT stream sends real JSON numbers and booleans. This decodes
/// either and exposes typed accessors that coerce, so the rest of the app never has to
/// care which transport a value arrived on.
public struct TelematicValue: Equatable, Sendable {
    public enum Raw: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    public let raw: Raw
    public let unit: String?
    public let timestamp: Date?

    public init(raw: Raw, unit: String? = nil, timestamp: Date? = nil) {
        self.raw = raw
        self.unit = unit
        self.timestamp = timestamp
    }

    public var doubleValue: Double? {
        switch raw {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        case .null: return nil
        }
    }

    public var intValue: Int? { doubleValue.map { Int($0.rounded()) } }

    public var stringValue: String? {
        switch raw {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        }
    }

    public var boolValue: Bool? {
        switch raw {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case .null: return nil
        }
    }
}

extension TelematicValue: Codable {
    private enum CodingKeys: String, CodingKey { case value, unit, timestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let d = try? container.decode(Double.self, forKey: .value) {
            raw = .number(d)
        } else if let b = try? container.decode(Bool.self, forKey: .value) {
            raw = .bool(b)
        } else if let s = try? container.decode(String.self, forKey: .value) {
            raw = .string(s)
        } else {
            raw = .null
        }

        unit = try? container.decodeIfPresent(String.self, forKey: .unit)
        timestamp = (try? container.decodeIfPresent(String.self, forKey: .timestamp))
            .flatMap { $0 }
            .flatMap(TelematicValue.parseTimestamp)
    }

    /// Re-encoded when the last known state is cached to disk, so a launch can show
    /// real values without spending an API call.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch raw {
        case .string(let s): try container.encode(s, forKey: .value)
        case .number(let d): try container.encode(d, forKey: .value)
        case .bool(let b): try container.encode(b, forKey: .value)
        case .null: try container.encodeNil(forKey: .value)
        }
        try container.encodeIfPresent(unit, forKey: .unit)
        if let timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: timestamp), forKey: .timestamp)
        }
    }

    /// BMW mixes fractional-second and whole-second ISO 8601 in the same payload.
    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
