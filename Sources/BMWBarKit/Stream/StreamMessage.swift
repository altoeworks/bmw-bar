import Foundation

/// One MQTT payload from BMW.
///
/// Messages are sparse deltas — only descriptors whose value changed are present — so
/// they are merged into `VehicleState` rather than replacing it.
public struct StreamMessage: Decodable, Sendable {
    public let vin: String?
    /// BMW's gcid, echoed back on every message.
    public let entityId: String?
    public let data: [String: TelematicValue]

    private enum CodingKeys: String, CodingKey { case vin, entityId, timestamp, data }

    /// When BMW emitted the message (as opposed to the per-descriptor timestamps).
    public let sentAt: Date?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = try container.decodeIfPresent(String.self, forKey: .vin)
        entityId = try container.decodeIfPresent(String.self, forKey: .entityId)
        data = try container.decodeIfPresent([String: TelematicValue].self, forKey: .data) ?? [:]
        sentAt = (try? container.decodeIfPresent(String.self, forKey: .timestamp))
            .flatMap { $0 }
            .flatMap(TelematicValue.parseTimestamp)
    }
}
