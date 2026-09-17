import Foundation

/// Durable storage for credentials.
///
/// Declared here, implemented on the platform by the Keychain. The domain and the
/// coordinator need somewhere to put tokens without knowing what secure hardware is
/// available, and the abstraction is what lets the whole token lifecycle be tested
/// without a device.
public protocol TokenStore: Sendable {
    func load() async throws -> TokenPair?
    func save(_ tokens: TokenPair) async throws
    func clear() async throws
}

/// Performs the token exchange against the identity provider.
///
/// Separated from the coordinator so that serialization, retry, and policy can be tested
/// against a stub that counts calls, which is the only way to prove the concurrency
/// behavior that matters here.
public protocol TokenRefreshing: Sendable {
    func refresh(using refreshToken: String) async throws -> TokenPair
}

/// The tenant's OpenID Connect configuration, resolved from an email domain.
///
/// Aperture never holds a credential. Identity belongs to the customer's provider, which
/// removes an entire class of liability: there is no password database to breach and no
/// credential-stuffing target, because there is nothing to stuff.
public struct OIDCConfiguration: Sendable, Equatable, Decodable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    /// Public by design. A distributed binary cannot hold a secret, which is precisely
    /// why the flow requires PKCE.
    public let clientID: String
    public let scopes: [String]

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case clientID = "client_id"
        case scopes
    }

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, scopes: [String]) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.scopes = scopes
    }

    /// Builds the authorization URL for a flow.
    ///
    /// `state` is separate from the PKCE verifier and serves a different purpose: PKCE
    /// binds the code to this client, `state` binds the redirect to this request and is
    /// what detects a cross-site request forgery against the callback.
    public func authorizationURL(challenge: PKCEChallenge, redirectURI: String, state: String) -> URL? {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: challenge.method)
        ]

        return components.url
    }
}
