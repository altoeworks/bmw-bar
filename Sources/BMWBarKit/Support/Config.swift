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
    /// Stable MQTT client identifier, minted once. A persistent session is keyed on it,
    /// so it must survive relaunches and the hourly token rotation alike — a fresh id
    /// each connect is exactly what threw away everything published while we were away.
    public var streamClientID: String?
    /// What BMW's broker turned out to allow, learned by trying. `nil` means untested.
    public var persistentSession: Bool?
    /// When that was last established, so a "no" can be re-tested rather than believed
    /// forever.
    public var persistentSessionTestedAt: Date?

    public init(
        clientID: String? = nil,
        vin: String? = nil,
        containerID: String? = nil,
        vehicleName: String? = nil,
        notifications: NotificationPreferences? = nil,
        polling: PollingPreferences? = nil,
        streamClientID: String? = nil,
        persistentSession: Bool? = nil,
        persistentSessionTestedAt: Date? = nil
    ) {
        self.clientID = clientID
        self.vin = vin
        self.containerID = containerID
        self.vehicleName = vehicleName
        self.notifications = notifications
        self.polling = polling
        self.streamClientID = streamClientID
        self.persistentSession = persistentSession
        self.persistentSessionTestedAt = persistentSessionTestedAt
    }

    public var notificationPreferences: NotificationPreferences {
        get { notifications ?? .default }
        set { notifications = newValue }
    }

    public var pollingPreferences: PollingPreferences {
        get { polling ?? .default }
        set { polling = newValue }
    }

    /// How long a "the broker refused a persistent session" verdict is trusted before
    /// being re-tested. BMW may change their mind; we should not cache a "no" forever.
    public static let persistentSessionRetestInterval: TimeInterval = 7 * 24 * 60 * 60

    /// The stable MQTT client id, minting and saving one on first use.
    public static func resolvedStreamClientID() -> String {
        var config = load()
        if let existing = config.streamClientID, !existing.isEmpty { return existing }
        let minted = "bmw-bar-\(UUID().uuidString.lowercased())"
        config.streamClientID = minted
        try? config.save()
        return minted
    }

    /// Whether to attempt a persistent session on the next connect. Untested and
    /// stale-negative both mean "try".
    public var shouldTryPersistentSession: Bool {
        guard let persistentSession else { return true }
        if persistentSession { return true }
        guard let testedAt = persistentSessionTestedAt else { return true }
        return Date().timeIntervalSince(testedAt) > Config.persistentSessionRetestInterval
    }

    /// Records what the broker actually did, so the next launch does not pay for a
    /// round trip it already knows will fail.
    public static func recordPersistentSession(_ supported: Bool) {
        var config = load()
        guard config.persistentSession != supported || config.persistentSessionTestedAt == nil
        else { return }
        config.persistentSession = supported
        config.persistentSessionTestedAt = Date()
        try? config.save()
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
