import Foundation

public enum AuthError: Error, CustomStringConvertible {
    case missingClientID
    case missingGCID
    case accessDenied
    case deviceCodeExpired
    case notAuthenticated
    case refreshTokenExpired
    case server(status: Int, code: String?, body: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .missingClientID:
            return "No CarData client ID. Set BMW_CLIENT_ID or run `--cli auth --client-id <id>`."
        case .missingGCID:
            return "Token response contained no gcid and the id_token had no `sub` claim."
        case .accessDenied:
            return "Authorization was denied in the BMW portal."
        case .deviceCodeExpired:
            return "The device code expired before it was approved. Start again."
        case .notAuthenticated:
            return "Not authenticated yet. Run `--cli auth` first."
        case .refreshTokenExpired:
            return "The refresh token expired (2 week limit). Run `--cli auth` again."
        case .server(let status, let code, let body):
            return "BMW returned HTTP \(status)\(code.map { " (\($0))" } ?? ""): \(body)"
        case .malformedResponse(let detail):
            return "Could not parse BMW's response: \(detail)"
        }
    }
}

/// What the user must do in a browser to approve this device.
public struct DeviceCodeGrant {
    public let userCode: String
    public let deviceCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    /// Minimum seconds between polls, per BMW's response.
    public let interval: TimeInterval
}

/// OAuth2 Device Code Flow (RFC 8628) with PKCE against BMW's GCDM.
public struct CarDataAuth {
    static let deviceCodeURL = URL(string: "https://customer.bmwgroup.com/gcdm/oauth/device/code")!
    static let tokenURL = URL(string: "https://customer.bmwgroup.com/gcdm/oauth/token")!
    static let scopes = "authenticate_user openid cardata:streaming:read cardata:api:read"

    public let clientID: String
    private let session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    // MARK: - Step 1 & 2: ask for a device code

    public func requestDeviceCode(pkce: PKCE) async throws -> DeviceCodeGrant {
        let body = [
            "client_id": clientID,
            "response_type": "device_code",
            "scope": Self.scopes,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
        ]
        let (data, response) = try await postForm(Self.deviceCodeURL, body)
        guard response.statusCode == 200 else {
            throw AuthError.server(
                status: response.statusCode,
                code: Self.errorCode(in: data),
                body: Self.snippet(data)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let expiresIn = json["expires_in"] as? Double
        else { throw AuthError.malformedResponse(Self.snippet(data)) }

        // `verification_uri_complete` already embeds the code, so the user only has
        // to approve. Fall back to the bare URI and make them type the code.
        let uriString = (json["verification_uri_complete"] as? String)
            ?? (json["verification_uri"] as? String)
        guard let uriString, let uri = URL(string: uriString) else {
            throw AuthError.malformedResponse("no verification_uri in \(Self.snippet(data))")
        }

        return DeviceCodeGrant(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: uri,
            expiresAt: Date().addingTimeInterval(expiresIn),
            interval: (json["interval"] as? Double) ?? 5
        )
    }

    // MARK: - Step 4: poll until the user approves

    /// Polls the token endpoint until approval, denial, or expiry of the device code.
    public func pollForTokens(grant: DeviceCodeGrant, pkce: PKCE) async throws -> TokenSet {
        var interval = grant.interval

        while Date() < grant.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let body = [
                "client_id": clientID,
                "device_code": grant.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "code_verifier": pkce.verifier,
            ]
            let (data, response) = try await postForm(Self.tokenURL, body)

            if response.statusCode == 200 {
                return try decodeTokens(data, previousGCID: nil)
            }

            // BMW signals flow state through the error code, not the status code
            // (it answers `authorization_pending` with 403 rather than RFC 8628's 400).
            switch Self.errorCode(in: data) {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw AuthError.accessDenied
            case "expired_token":
                throw AuthError.deviceCodeExpired
            case let code:
                throw AuthError.server(
                    status: response.statusCode,
                    code: code,
                    body: Self.snippet(data)
                )
            }
        }
        throw AuthError.deviceCodeExpired
    }

    // MARK: - Step 6: refresh

    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        if tokens.isRefreshTokenExpired() { throw AuthError.refreshTokenExpired }

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
        ]
        let (data, response) = try await postForm(Self.tokenURL, body)
        guard response.statusCode == 200 else {
            throw AuthError.server(
                status: response.statusCode,
                code: Self.errorCode(in: data),
                body: Self.snippet(data)
            )
        }
        return try decodeTokens(data, previousGCID: tokens.gcid)
    }

    // MARK: - Helpers

    private func decodeTokens(_ data: Data, previousGCID: String?) throws -> TokenSet {
        do {
            return try JSONDecoder()
                .decode(TokenResponse.self, from: data)
                .tokenSet(previousGCID: previousGCID)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.malformedResponse(Self.snippet(data))
        }
    }

    private func postForm(
        _ url: URL,
        _ fields: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(Self.formURLEncode(fields).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    static func formURLEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? fields[key]!
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func errorCode(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["error"] as? String) ?? (json["error_description"] as? String)
    }

    static func snippet(_ data: Data, limit: Int = 400) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
