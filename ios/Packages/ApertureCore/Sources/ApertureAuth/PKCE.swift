import Foundation
import Crypto
import ApertureDomain

/// Proof Key for Code Exchange, RFC 7636.
///
/// Mandatory for this client and not optional hardening. Aperture is a public OAuth
/// client: the binary is distributed to devices an attacker controls, so it cannot hold a
/// client secret. Without PKCE, anyone who intercepts the redirect (a malicious app
/// registering the same URL scheme, a hostile network, a shoulder-surfer reading a URL
/// bar) can exchange the authorization code for tokens. PKCE binds the code to a secret
/// that never leaves the process that started the flow.
public struct PKCEChallenge: Sendable, Equatable {
    /// Held in memory only, never persisted. Writing it to disk would defeat the purpose:
    /// the whole point is that it exists only inside the process that began the exchange.
    public let verifier: String

    /// Sent with the authorization request.
    public let challenge: String

    /// Always S256. The `plain` method RFC 7636 also defines is not used, because it sends
    /// the verifier itself and therefore protects nothing.
    public let method = "S256"

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum PKCE {
    /// The unreserved character set from RFC 3986, which RFC 7636 requires for verifiers.
    /// Restricted to these so the value survives URL encoding unchanged.
    static let unreservedCharacters = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// RFC 7636 permits 43 to 128 characters. 64 is comfortably above the floor and leaves
    /// room in any URL length budget.
    public static let defaultVerifierLength = 64
    public static let minimumVerifierLength = 43
    public static let maximumVerifierLength = 128

    /// Mints a verifier and its challenge.
    public static func generate(
        random: any RandomSource,
        verifierLength: Int = defaultVerifierLength
    ) -> PKCEChallenge {
        precondition(
            (minimumVerifierLength...maximumVerifierLength).contains(verifierLength),
            "RFC 7636 requires a verifier of 43 to 128 characters"
        )

        let verifier = String(
            (0..<verifierLength).map { _ in
                let index = Int(random.value(upperBound: UInt64(unreservedCharacters.count)))
                return unreservedCharacters[index]
            }
        )

        return PKCEChallenge(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, with padding removed.
    ///
    /// Base64url rather than standard base64 because the value travels in a query
    /// parameter, where `+` and `/` would be re-encoded and `=` is reserved.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
