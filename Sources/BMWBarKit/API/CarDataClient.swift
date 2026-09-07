import Foundation

public enum CarDataError: Error, CustomStringConvertible {
    case http(status: Int, message: String?, body: String)
    case decoding(String)

    public var description: String {
        switch self {
        case .http(let status, let message, let body):
            let detail = message ?? body
            switch status {
            case 401:
                return "BMW rejected the token (401). Try `--cli auth --force`. \(detail)"
            case 403:
                return """
                    BMW refused access (403). The client ID usually needs "CarData API" \
                    access requested in the portal, and permissions take a minute to \
                    propagate. \(detail)
                    """
            case 429:
                return "BMW rate-limited the request (429): \(detail)"
            default:
                return "BMW returned HTTP \(status): \(detail)"
            }
        case .decoding(let detail):
            return "Could not decode BMW's response: \(detail)"
        }
    }
}

/// REST client for the CarData customer API.
///
/// Every request spends part of a 50/day budget, so each method declares whether it is
/// essential (allowed to dip into the reserve) or optional.
public actor CarDataClient {
    static let baseURL = URL(string: "https://api-cardata.bmwgroup.com")!

    private let tokens: TokenStore
    private let quota: QuotaTracker
    private let session: URLSession

    public init(tokens: TokenStore, quota: QuotaTracker, session: URLSession = .shared) {
        self.tokens = tokens
        self.quota = quota
        self.session = session
    }

    public func quotaSnapshot() async -> QuotaSnapshot { await quota.snapshot() }

    // MARK: - Vehicles

    /// Vehicles mapped to the account. Essential: nothing works without a VIN.
    public func vehicleMappings() async throws -> [VehicleMapping] {
        let data = try await get("/customers/vehicles/mappings", essential: true)
        // BMW documents a single DTO but returns a list; accept either shape, and a
        // wrapper object too, rather than breaking on a schema detail.
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([VehicleMapping].self, from: data) { return list }
        if let one = try? decoder.decode(VehicleMapping.self, from: data) { return [one] }
        struct Wrapper: Decodable { let vehicles: [VehicleMapping]? }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data), let v = wrapped.vehicles {
            return v
        }
        throw CarDataError.decoding(Self.snippet(data))
    }

    /// Static vehicle description. Essential: fetched once, then cached in config.
    public func basicData(vin: String) async throws -> VehicleBasicData {
        let data = try await get("/customers/vehicles/\(vin)/basicData", essential: true)
        return try decode(VehicleBasicData.self, from: data)
    }

    /// A full snapshot of the container's descriptors. Essential: this is what fills
    /// the panel at launch, before the first stream message arrives.
    public func telematicData(vin: String, containerID: String) async throws -> [String: TelematicValue] {
        let data = try await get(
            "/customers/vehicles/\(vin)/telematicData",
            query: [URLQueryItem(name: "containerId", value: containerID)],
            essential: true
        )
        return try decode(TelematicDataResponse.self, from: data).telematicData ?? [:]
    }

    // MARK: - Containers

    public func listContainers() async throws -> [Container] {
        let data = try await get("/customers/containers", essential: true)
        if let list = try? JSONDecoder().decode(ContainerList.self, from: data) {
            return list.containers ?? []
        }
        if let array = try? JSONDecoder().decode([Container].self, from: data) { return array }
        throw CarDataError.decoding(Self.snippet(data))
    }

    public func createContainer(
        name: String,
        purpose: String,
        descriptors: [String]
    ) async throws -> Container {
        let body: [String: Any] = [
            "name": name,
            "purpose": purpose,
            "technicalDescriptors": descriptors,
        ]
        let data = try await request(
            method: "POST",
            path: "/customers/containers",
            body: try JSONSerialization.data(withJSONObject: body),
            essential: true
        )
        return try decode(Container.self, from: data)
    }

    public func deleteContainer(id: String) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/customers/containers/\(id)",
            essential: true
        )
    }

    // MARK: - Transport

    private func get(
        _ path: String,
        query: [URLQueryItem] = [],
        essential: Bool
    ) async throws -> Data {
        try await request(method: "GET", path: path, query: query, essential: essential)
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        essential: Bool
    ) async throws -> Data {
        // Reserve the budget slot before spending it on the wire.
        try await quota.consume(essential: essential)

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("v1", forHTTPHeaderField: "x-version")
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let token = try await tokens.validTokens().accessToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var (data, response) = try await send(request)

        // A 401 despite a token we believed valid means BMW invalidated it early;
        // one forced refresh, one retry, then give up.
        if response.statusCode == 401 {
            let refreshed = try await tokens.forceRefresh()
            request.setValue(
                "Bearer \(refreshed.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            try await quota.consume(essential: true)
            (data, response) = try await send(request)
        }

        guard (200..<300).contains(response.statusCode) else {
            // BMW answers an exhausted budget with CU-429. Believe it over the local
            // counter, which is only a mirror and can drift.
            let text = String(data: data, encoding: .utf8) ?? ""
            if response.statusCode == 429 || text.contains("CU-429") {
                await quota.markExhaustedByServer()
            }
            throw CarDataError.http(
                status: response.statusCode,
                message: try? JSONDecoder()
                    .decode(CarDataErrorBody.self, from: data).message,
                body: Self.snippet(data)
            )
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CarDataError.decoding("non-HTTP response")
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CarDataError.decoding("\(error) in \(Self.snippet(data))")
        }
    }

    static func snippet(_ data: Data, limit: Int = 500) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
