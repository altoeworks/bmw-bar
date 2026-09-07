import CryptoKit
import Foundation
import Security

/// RFC 7636 code verifier / challenge pair, `S256` method.
public struct PKCE: Equatable {
    public let verifier: String
    public let challenge: String

    /// Fresh pair from 32 cryptographically random bytes.
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        self.init(verifier: Data(bytes).base64URLEncodedString)
    }

    /// Derives the challenge from a known verifier. Exposed for tests.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }
}
