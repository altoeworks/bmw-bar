import Foundation

/// Where the app keeps non-secret state. Secrets go to the Keychain instead.
public enum AppPaths {
    public static let bundleIdentifier = "com.ohoefenstock.bmw-bar"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("bmw-bar", isDirectory: true)
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var quotaFile: URL { supportDirectory.appendingPathComponent("quota.json") }

    /// Creates the support directory if needed. Safe to call repeatedly.
    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Writes atomically with owner-only permissions.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try ensureSupportDirectory()
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
