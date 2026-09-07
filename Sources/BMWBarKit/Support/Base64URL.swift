import Foundation

extension Data {
    /// Unpadded base64url, as required by RFC 7636 (PKCE).
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url, re-adding the padding the encoder stripped.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if s.count % 4 != 0 {
            s.append(String(repeating: "=", count: 4 - s.count % 4))
        }
        self.init(base64Encoded: s)
    }
}
