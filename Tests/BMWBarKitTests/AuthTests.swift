import Foundation
import Testing
@testable import BMWBarKit

// XCTest ships only with Xcode.app; this machine has Command Line Tools, which
// provide swift-testing. That's the modern framework anyway.

@Suite("PKCE")
struct PKCETests {
    /// The worked example from RFC 7636 Appendix B.
    @Test func challengeMatchesRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func challengeIsUnpaddedBase64URL() {
        let challenge = PKCE().challenge
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        // SHA-256 is 32 bytes -> 43 base64 characters once padding is stripped.
        #expect(challenge.count == 43)
    }

    @Test func verifiersAreUnique() {
        #expect(PKCE().verifier != PKCE().verifier)
    }
}

@Suite("base64url")
struct Base64URLTests {
    @Test(arguments: 1...12)
    func roundTripsWithoutPadding(length: Int) {
        let data = Data((0..<length).map { UInt8($0) })
        #expect(Data(base64URLEncoded: data.base64URLEncodedString) == data)
    }
}

@Suite("Token expiry")
struct TokenSetTests {
    private func makeTokens(accessLifetime: TimeInterval, now: Date = Date()) -> TokenSet {
        TokenSet(
            accessToken: "a",
            idToken: "i",
            refreshToken: "r",
            gcid: "g",
            accessExpiresAt: now.addingTimeInterval(accessLifetime),
            refreshExpiresAt: now.addingTimeInterval(14 * 24 * 3600)
        )
    }

    @Test func freshTokenIsNotStale() {
        #expect(!makeTokens(accessLifetime: 3600).isAccessTokenStale())
    }

    /// 4 minutes left against a 5 minute buffer: refresh before a request can race it.
    @Test func tokenIsStaleInsideTheRefreshBuffer() {
        #expect(makeTokens(accessLifetime: 4 * 60).isAccessTokenStale())
    }

    @Test func expiredTokenIsStale() {
        #expect(makeTokens(accessLifetime: -1).isAccessTokenStale())
    }

    @Test func refreshTokenExpiresAfterTwoWeeks() {
        let now = Date()
        let tokens = makeTokens(accessLifetime: 3600, now: now)
        #expect(!tokens.isRefreshTokenExpired(asOf: now))
        #expect(tokens.isRefreshTokenExpired(asOf: now.addingTimeInterval(15 * 24 * 3600)))
    }
}

@Suite("Token response decoding")
struct TokenResponseTests {
    private let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func decode(_ json: String) throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
    }

    @Test func decodesResponseAndComputesExpiry() throws {
        let response = try decode("""
        {"access_token":"AT","id_token":"IT","refresh_token":"RT",
         "expires_in":3599,"token_type":"Bearer","gcid":"GCID-1"}
        """)
        let tokens = try response.tokenSet(issuedAt: issuedAt)

        #expect(tokens.accessToken == "AT")
        #expect(tokens.idToken == "IT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.gcid == "GCID-1")
        #expect(tokens.accessExpiresAt == issuedAt.addingTimeInterval(3599))
        #expect(tokens.refreshExpiresAt == issuedAt.addingTimeInterval(14 * 24 * 3600))
    }

    /// A refresh response may omit `gcid`; the JWT `sub` claim then supplies it.
    @Test func fallsBackToIDTokenSubject() throws {
        let payload = Data(#"{"sub":"GCID-FROM-JWT"}"#.utf8).base64URLEncodedString
        let response = try decode("""
        {"access_token":"AT","id_token":"h.\(payload).s","refresh_token":"RT","expires_in":3600}
        """)
        #expect(try response.tokenSet(issuedAt: issuedAt).gcid == "GCID-FROM-JWT")
    }

    /// And if the JWT carries no usable claim, the previous gcid carries over.
    @Test func fallsBackToPreviousGCID() throws {
        let response = try decode("""
        {"access_token":"AT","id_token":"opaque","refresh_token":"RT","expires_in":3600}
        """)
        #expect(try response.tokenSet(issuedAt: issuedAt, previousGCID: "GCID-OLD").gcid == "GCID-OLD")
    }

    @Test func throwsWhenNoGCIDIsAvailableAnywhere() throws {
        let response = try decode("""
        {"access_token":"AT","id_token":"opaque","refresh_token":"RT","expires_in":3600}
        """)
        #expect(throws: AuthError.self) { try response.tokenSet(issuedAt: issuedAt) }
    }
}

@Suite("Form encoding")
struct FormEncodingTests {
    @Test func encodesReservedCharacters() {
        let encoded = CarDataAuth.formURLEncode([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": "abc",
        ])
        #expect(
            encoded ==
            "client_id=abc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        )
    }

    @Test func extractsOAuthErrorCode() {
        #expect(
            CarDataAuth.errorCode(in: Data(#"{"error":"authorization_pending"}"#.utf8))
                == "authorization_pending"
        )
        #expect(CarDataAuth.errorCode(in: Data("not json".utf8)) == nil)
    }
}
