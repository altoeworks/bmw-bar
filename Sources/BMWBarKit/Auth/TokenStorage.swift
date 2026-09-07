import Foundation

/// Where the token set is persisted between launches.
public protocol TokenStorage: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}

/// Owner-only file under Application Support.
///
/// This is the default. The Keychain would be the more obvious home, but an
/// ad-hoc-signed app gets a fresh code signature on every rebuild, and macOS then
/// prompts for the login password each time it tries to read the item. A `0600`
/// file in a `0700` directory avoids that, is covered by FileVault at rest, and is
/// the same posture `~/.ssh` and most CLI tools use. Set `BMW_BAR_STORAGE=keychain`
/// to opt into the Keychain once the app is signed with a stable identity.
public struct FileTokenStorage: TokenStorage {
    private var url: URL { AppPaths.supportDirectory.appendingPathComponent("tokens.json") }

    public init() {}

    public func load() throws -> TokenSet? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) throws {
        try AppPaths.writePrivate(JSONEncoder().encode(tokens), to: url)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: url)
    }
}

public struct KeychainTokenStorage: TokenStorage {
    private let account = "cardata-tokens"

    public init() {}

    public func load() throws -> TokenSet? {
        guard let data = try Keychain.read(account: account) else { return nil }
        return try JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) throws {
        try Keychain.write(JSONEncoder().encode(tokens), account: account)
    }

    public func clear() throws {
        try Keychain.delete(account: account)
    }
}

public enum TokenStorageFactory {
    /// Honours `BMW_BAR_STORAGE=keychain`; otherwise the file store.
    public static func makeDefault() -> TokenStorage {
        let choice = ProcessInfo.processInfo.environment["BMW_BAR_STORAGE"]?.lowercased()
        return choice == "keychain" ? KeychainTokenStorage() : FileTokenStorage()
    }
}
