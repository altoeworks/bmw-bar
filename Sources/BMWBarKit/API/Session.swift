import Foundation

/// Wires the auth, quota and REST pieces together and resolves the one-time setup
/// (which VIN, which container) that the rest of the app depends on.
public struct Session {
    public let clientID: String
    public let auth: CarDataAuth
    public let tokens: TokenStore
    public let quota: QuotaTracker
    public let client: CarDataClient

    public static let containerName = "bmw-bar"
    public static let containerPurpose = "macOS status bar monitor"

    public init(clientID: String) {
        self.clientID = clientID
        let auth = CarDataAuth(clientID: clientID)
        let tokens = TokenStore(auth: auth)
        let quota = QuotaTracker()
        self.auth = auth
        self.tokens = tokens
        self.quota = quota
        self.client = CarDataClient(tokens: tokens, quota: quota)
    }

    public static func make(clientIDOverride: String? = nil) throws -> Session {
        guard let clientID = Config.resolvedClientID(override: clientIDOverride) else {
            throw AuthError.missingClientID
        }
        return Session(clientID: clientID)
    }

    /// What the app needs before it can show anything, resolved once and cached in
    /// `config.json` so later launches spend no quota on it.
    public struct Setup {
        public let vin: String
        public let containerID: String
        public let vehicleName: String?
        public let batteryCapacityKWh: Double?
        /// True when this run had to call BMW (and therefore spent quota).
        public let didFetch: Bool
    }

    /// Resolves VIN and container, reusing the cached values when present.
    /// - Parameter refresh: ignore the cache and re-resolve from BMW.
    public func bootstrap(refresh: Bool = false) async throws -> Setup {
        var config = Config.load()

        if !refresh, let vin = config.vin, let containerID = config.containerID {
            return Setup(
                vin: vin,
                containerID: containerID,
                vehicleName: config.vehicleName,
                batteryCapacityKWh: nil,
                didFetch: false
            )
        }

        // Each step is persisted as soon as it succeeds. BMW's budget is 50 calls a
        // day, so a failure late in setup must not make the next attempt re-buy the
        // steps that already worked.
        let vin = try await resolveVIN(cached: refresh ? nil : config.vin)
        if config.vin != vin {
            config.vin = vin
            try? config.save()
        }

        var basicData: VehicleBasicData?
        if config.vehicleName == nil || refresh {
            basicData = try? await client.basicData(vin: vin)
            if let name = basicData?.displayName {
                config.vehicleName = name
                try? config.save()
            }
        }

        let containerID = try await resolveContainer(cached: refresh ? nil : config.containerID)
        config.containerID = containerID
        try config.save()

        return Setup(
            vin: vin,
            containerID: containerID,
            vehicleName: config.vehicleName,
            batteryCapacityKWh: basicData?.batteryCapacityKWh,
            didFetch: true
        )
    }

    private func resolveVIN(cached: String?) async throws -> String {
        if let cached { return cached }

        let mappings = try await client.vehicleMappings()
        guard !mappings.isEmpty else { throw SetupError.noVehicles }
        // Streaming requires PRIMARY mapping, so prefer it; fall back to whatever
        // exists so the REST side still works for a secondary driver.
        return (mappings.first(where: \.isPrimary) ?? mappings[0]).vin
    }

    private func resolveContainer(cached: String?) async throws -> String {
        if let cached { return cached }

        // Reuse ours if a previous install left one behind, rather than piling up
        // containers on the account.
        let existing = try await client.listContainers()
        if let mine = existing.first(where: { $0.name == Self.containerName && $0.isActive }) {
            return mine.containerId
        }
        do {
            return try await client.createContainer(
                name: Self.containerName,
                purpose: Self.containerPurpose,
                descriptors: Descriptor.all
            ).containerId
        } catch let error as CarDataError {
            // BMW fails the whole request if any single descriptor is unknown or
            // deprecated. DescriptorCatalogueTests guards against this, but BMW can
            // retire an id after the fixture was captured.
            if case .http(_, let message, let body) = error,
               (message ?? body).contains("CU-402") {
                throw SetupError.invalidDescriptors(detail: message ?? body)
            }
            throw error
        }
    }
}

public enum SetupError: Error, CustomStringConvertible {
    case noVehicles
    case notSetUp
    case invalidDescriptors(detail: String)

    public var description: String {
        switch self {
        case .noVehicles:
            return """
                BMW reports no vehicles on this account. Check that the car is mapped \
                to you in MyBMW and that CarData is enabled for it.
                """
        case .notSetUp:
            return "No VIN or container stored yet. Run `--cli setup` first."
        case .invalidDescriptors(let detail):
            return """
                BMW rejected the telemetry container because one of the requested data \
                fields is no longer valid (CU-402). Refresh the catalogue with \
                Scripts/fetch-catalogue.sh and run the tests to find which one. \(detail)
                """
        }
    }
}
