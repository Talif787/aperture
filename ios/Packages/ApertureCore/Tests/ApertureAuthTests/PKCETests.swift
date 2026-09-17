import Testing
import Foundation
@testable import ApertureAuth
import ApertureDomain
import ApertureTestSupport

@Suite("PKCE")
struct PKCETests {

    @Test("matches the RFC 7636 reference vector")
    func referenceVector() {
        // Appendix B of RFC 7636. If this passes, the digest, the base64url alphabet, and
        // the padding removal are all correct together, which no amount of testing the
        // pieces separately would establish.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("the challenge is base64url, with no characters that a query string would re-encode")
    func base64URLAlphabet() {
        let challenge = PKCE.generate(random: SeededRandomSource(seed: 5)).challenge

        #expect(challenge.contains("+") == false)
        #expect(challenge.contains("/") == false)
        #expect(challenge.contains("=") == false)
    }

    @Test("verifiers use only the RFC 3986 unreserved set")
    func verifierCharacterSet() {
        let permitted = Set(PKCE.unreservedCharacters)

        for seed in UInt64(1)...20 {
            let verifier = PKCE.generate(random: SeededRandomSource(seed: seed)).verifier
            #expect(verifier.allSatisfy { permitted.contains($0) }, "seed \(seed) produced \(verifier)")
        }
    }

    @Test("verifier length sits inside the range the specification permits", arguments: [43, 64, 128])
    func verifierLength(length: Int) {
        let challenge = PKCE.generate(random: SeededRandomSource(seed: 3), verifierLength: length)

        #expect(challenge.verifier.count == length)
    }

    @Test("two flows never share a verifier")
    func verifiersAreDistinct() {
        let random = SeededRandomSource(seed: 11)

        let verifiers = (0..<200).map { _ in PKCE.generate(random: random).verifier }

        #expect(Set(verifiers).count == 200)
    }

    @Test("the challenge is deterministic for a given verifier")
    func challengeIsAFunctionOfTheVerifier() {
        let challenge = PKCE.generate(random: SeededRandomSource(seed: 7))

        #expect(PKCE.challenge(for: challenge.verifier) == challenge.challenge)
    }

    @Test("only S256 is offered")
    func plainMethodIsNotUsed() {
        // RFC 7636 also defines `plain`, which transmits the verifier itself and therefore
        // protects nothing. It is not implemented rather than merely not preferred.
        #expect(PKCE.generate(random: SeededRandomSource(seed: 1)).method == "S256")
    }

    @Test("the authorization URL carries the challenge and not the verifier")
    func authorizationURLOmitsTheVerifier() throws {
        let configuration = try Self.testConfiguration()
        let challenge = PKCE.generate(random: SeededRandomSource(seed: 2))

        let url = try #require(
            configuration.authorizationURL(
                challenge: challenge,
                redirectURI: "com.aperture.field://callback",
                state: "state-123"
            )
        )
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        #expect(values["code_challenge"] == challenge.challenge)
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["response_type"] == "code")
        #expect(values["scope"] == "openid profile aperture.inspector")
        // The verifier must never appear in a URL. It is the one value whose secrecy the
        // entire exchange depends on.
        #expect(url.absoluteString.contains(challenge.verifier) == false)
    }

    /// Built through `#require` rather than force unwrapping, because the project rejects
    /// force unwraps everywhere including tests: a crash in a test tells you which line
    /// died but not what was nil, while a required value reports the failure.
    private static func testConfiguration() throws -> OIDCConfiguration {
        OIDCConfiguration(
            issuer: try #require(URL(string: "https://carrier.example/oauth2")),
            authorizationEndpoint: try #require(URL(string: "https://carrier.example/oauth2/v1/authorize")),
            tokenEndpoint: try #require(URL(string: "https://carrier.example/oauth2/v1/token")),
            clientID: "0oa1b2c3d4",
            scopes: ["openid", "profile", "aperture.inspector"]
        )
    }
}
