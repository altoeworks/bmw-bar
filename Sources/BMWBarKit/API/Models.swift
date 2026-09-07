import Foundation

/// A vehicle on the account. Streaming requires PRIMARY mapping.
public struct VehicleMapping: Decodable, Equatable, Sendable {
    public let vin: String
    public let mappingType: String?
    public let mappedSince: String?

    public var isPrimary: Bool { mappingType?.uppercased() == "PRIMARY" }
}

/// Static vehicle description — model name, battery size, etc.
public struct VehicleBasicData: Decodable, Equatable, Sendable {
    public let vin: String?
    public let brand: String?
    public let modelName: String?
    public let modelRange: String?
    public let series: String?
    public let driveTrain: String?
    public let propulsionType: String?
    public let headUnit: String?
    public let isTelematicsCapable: Bool?
    /// Gross pack capacity in kWh, as a string in BMW's schema.
    public let reessNominalCapacityGross: String?
    public let hvsMaxEnergyAbsolute: String?

    /// Best available human-readable name, e.g. "BMWi i4 eDrive40".
    public var displayName: String {
        let parts = [brand, modelName ?? modelRange].compactMap { $0 }
        return parts.isEmpty ? (vin ?? "Vehicle") : parts.joined(separator: " ")
    }

    public var batteryCapacityKWh: Double? {
        reessNominalCapacityGross.flatMap(Double.init)
            ?? hvsMaxEnergyAbsolute.flatMap(Double.init)
    }
}

/// A "container": the named set of descriptors an API read returns.
public struct Container: Decodable, Equatable, Sendable {
    public let containerId: String
    public let name: String?
    public let purpose: String?
    public let state: String?
    public let technicalDescriptors: [String]?

    public var isActive: Bool { (state ?? "ACTIVE").uppercased() == "ACTIVE" }
}

struct ContainerList: Decodable {
    let containers: [Container]?
}

struct TelematicDataResponse: Decodable {
    let telematicData: [String: TelematicValue]?
}

/// BMW's error envelope, so failures carry their message rather than a bare status.
struct CarDataErrorBody: Decodable {
    let exveErrorId: String?
    let exveErrorMsg: String?
    let exveNote: String?

    var message: String? {
        [exveErrorId, exveErrorMsg, exveNote].compactMap { $0 }.joined(separator: " — ")
            .nonEmpty
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
