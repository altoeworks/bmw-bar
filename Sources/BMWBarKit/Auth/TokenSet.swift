import Foundation

/// The credentials BMW hands back, plus the expiry instants we compute locally.
///
/// Three distinct tokens, used in three different places:
/// - `accessToken` — `Authorization: Bearer` for the CarData REST API (1 h)
/// - `idToken`     — the MQTT *password* for the streaming broker (1 h)
/// - `refreshToken` — renews all of the above (2 weeks, rotated on every use)
public struct TokenSet: Codable, Equatable {
    public var accessToken: String
    public var idToken: String
    public var refreshToken: String
    /// BMW customer id. Doubles as the MQTT username and the stream topic prefix.
    public var gcid: String
    public var accessExpiresAt: Date
    public var refreshExpiresAt: Date

    public init(
        accessToken: String,
        idToken: String,
        refreshToken: String,
        gcid: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date
    ) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.gcid = gcid
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }

    /// Refresh this far ahead of expiry so a request never races the deadline.
    public static let refreshBuffer: TimeInterval = 5 * 60

    public func isAccessTokenStale(asOf now: Date = Date()) -> Bool {
        now.addingTimeInterval(Self.refreshBuffer) >= accessExpiresAt
    }

    public func isRefreshTokenExpired(asOf now: Date = Date()) -> Bool {
        now >= refreshExpiresAt
    }
}

/// Raw shape of BMW's token endpoint response.
struct TokenResponse: Decodable {
    let accessToken: String
    let idToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let gcid: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case gcid
    }

    /// BMW documents a two-week refresh token but does not return its lifetime.
    static let refreshTokenLifetime: TimeInterval = 14 * 24 * 60 * 60

    /// - Parameter previousGCID: kept when a refresh response omits `gcid`.
    func tokenSet(issuedAt: Date = Date(), previousGCID: String? = nil) throws -> TokenSet {
        guard let gcid = gcid ?? JWT.subject(of: idToken) ?? previousGCID else {
            throw AuthError.missingGCID
        }
        return TokenSet(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            gcid: gcid,
            accessExpiresAt: issuedAt.addingTimeInterval(expiresIn),
            refreshExpiresAt: issuedAt.addingTimeInterval(Self.refreshTokenLifetime)
        )
    }
}

/// Just enough JWT handling to read a claim. No signature verification: the token
/// arrives over TLS from the issuer we just authenticated against, and we only use
/// it as an opaque credential plus a fallback source for the `sub` claim.
enum JWT {
    static func subject(of token: String) -> String? {
        claims(of: token)?["sub"] as? String
    }

    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload)
        else { return nil }
        return json as? [String: Any]
    }
}
