import Foundation

/// Owns the token lifecycle: persistence, proactive refresh, and de-duplication of
/// concurrent refreshes.
///
/// Every refresh rotates the refresh token, so two overlapping refreshes would burn
/// each other's token and lock the session out. The actor serialises them and callers
/// share one in-flight refresh.
public actor TokenStore {
    private let auth: CarDataAuth
    private let storage: TokenStorage
    private var tokens: TokenSet?
    private var refreshTask: Task<TokenSet, Error>?

    public init(auth: CarDataAuth, storage: TokenStorage = TokenStorageFactory.makeDefault()) {
        self.auth = auth
        self.storage = storage
    }

    /// Reads persisted tokens into memory. Returns nil when the device has never
    /// been authorised.
    @discardableResult
    public func loadPersisted() throws -> TokenSet? {
        if tokens == nil { tokens = try storage.load() }
        return tokens
    }

    public func hasCredentials() -> Bool {
        ((try? loadPersisted()) ?? nil) != nil
    }

    /// Stores a freshly issued token set (after the device code flow completed).
    public func adopt(_ new: TokenSet) throws {
        tokens = new
        try storage.save(new)
    }

    public func signOut() throws {
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        try storage.clear()
    }

    /// A token set guaranteed valid for at least `TokenSet.refreshBuffer` seconds.
    public func validTokens() async throws -> TokenSet {
        guard let current = try loadPersisted() else { throw AuthError.notAuthenticated }
        guard current.isAccessTokenStale() else { return current }
        return try await refreshNow(from: current)
    }

    /// Forces a refresh regardless of expiry — used when the stream needs a fresh
    /// `id_token` or when BMW rejects a token we believed was good.
    @discardableResult
    public func forceRefresh() async throws -> TokenSet {
        guard let current = try loadPersisted() else { throw AuthError.notAuthenticated }
        return try await refreshNow(from: current)
    }

    private func refreshNow(from current: TokenSet) async throws -> TokenSet {
        if let existing = refreshTask { return try await existing.value }

        let task = Task { [auth, storage] () throws -> TokenSet in
            let refreshed = try await auth.refresh(current)
            // Persist before returning: the old refresh token is already spent.
            try storage.save(refreshed)
            return refreshed
        }
        refreshTask = task

        defer { refreshTask = nil }
        let refreshed = try await task.value
        tokens = refreshed
        return refreshed
    }
}
