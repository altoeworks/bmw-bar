import Foundation

/// Non-secret settings persisted between launches.
///
/// The CarData client ID is not a secret in the OAuth sense (device code flow is a
/// public-client flow with PKCE), so it lives here rather than in the Keychain.
public struct Config: Codable, Equatable {
    public var clientID: String?
    public var vin: String?
    public var containerID: String?
    public var vehicleName: String?
    /// Absent in configs written before notifications existed, so it resolves to the
    /// defaults rather than failing to decode.
    public var notifications: NotificationPreferences?
    /// Absent in configs written before idle polling existed.
    public var polling: PollingPreferences?

    public init(
        clientID: String? = nil,
        vin: String? = nil,
        containerID: String? = nil,
        vehicleName: String? = nil,
        notifications: NotificationPreferences? = nil,
        polling: PollingPreferences? = nil
    ) {
        self.clientID = clientID
        self.vin = vin
        self.containerID = containerID
        self.vehicleName = vehicleName
        self.notifications = notifications
        self.polling = polling
    }

    public var notificationPreferences: NotificationPreferences {
        get { notifications ?? .default }
        set { notifications = newValue }
    }

    public var pollingPreferences: PollingPreferences {
        get { polling ?? .default }
        set { polling = newValue }
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppPaths.writePrivate(encoder.encode(self), to: AppPaths.configFile)
    }

    /// Client ID from, in order: the environment, then the saved config.
    /// The environment override keeps CLI experiments from clobbering saved state.
    public static func resolvedClientID(override: String? = nil) -> String? {
        if let override, !override.isEmpty { return override }
        if let env = ProcessInfo.processInfo.environment["BMW_CLIENT_ID"], !env.isEmpty { return env }
        return load().clientID
    }
}
