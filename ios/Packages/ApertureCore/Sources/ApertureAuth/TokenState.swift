import Foundation

/// The credentials a session holds.
///
/// Access tokens are deliberately short-lived, at fifteen minutes. That bounds the damage
/// from a stolen token to a window rather than a month, and it is short enough to matter
/// while long enough not to thrash a marginal cellular link with refreshes.
public struct TokenPair: Sendable, Equatable {
    public let accessToken: String
    public let accessTokenExpiry: Date

    /// Opaque and rotating. Every use produces a new one, and presenting a consumed token
    /// is treated as evidence of theft rather than as a retry.
    public let refreshToken: String
    public let refreshTokenExpiry: Date

    public let issuedAt: Date

    public init(
        accessToken: String,
        accessTokenExpiry: Date,
        refreshToken: String,
        refreshTokenExpiry: Date,
        issuedAt: Date
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshToken = refreshToken
        self.refreshTokenExpiry = refreshTokenExpiry
        self.issuedAt = issuedAt
    }

    /// Tolerance applied when judging expiry.
    ///
    /// A token that expires in five seconds is treated as already expired, because the
    /// request carrying it may not arrive before it does. Without the skew allowance a
    /// client on a slow link produces a steady trickle of 401s that each cost a round
    /// trip to discover.
    public static let clockSkewAllowance: TimeInterval = 60

    public func isAccessTokenUsable(at instant: Date, skew: TimeInterval = clockSkewAllowance) -> Bool {
        instant.addingTimeInterval(skew) < accessTokenExpiry
    }

    public func isRefreshTokenUsable(at instant: Date) -> Bool {
        instant < refreshTokenExpiry
    }

    public func accessTokenLifetimeRemaining(at instant: Date) -> TimeInterval {
        max(0, accessTokenExpiry.timeIntervalSince(instant))
    }
}

/// Failures the authentication layer distinguishes.
///
/// The distinctions drive different behavior, which is the only reason to have them.
/// A network failure means the outcome is unknown and the session should survive; an
/// `invalidGrant` means the token is genuinely dead and the session must not.
public enum AuthError: Error, Equatable, Sendable {
    /// The refresh token was rejected. Terminal: clear state and reauthenticate.
    case invalidGrant

    /// A consumed refresh token was presented again.
    ///
    /// Under rotation this means either a genuine replay by an attacker or a client bug
    /// that used the same token twice. Both are handled identically and severely: the
    /// entire token family is revoked server-side. This is why refresh must be serialized
    /// on the client, since two concurrent refreshes produce exactly this signature and
    /// log the user out for no reason they can see.
    case refreshTokenReuseDetected

    /// The refresh could not be attempted. The session survives; see `SessionPolicy`.
    case networkUnavailable

    /// The identity provider rejected the request for a reason worth surfacing.
    case providerRejected(code: String)

    /// No credentials are held at all.
    case notAuthenticated

    public var isTerminal: Bool {
        switch self {
        case .invalidGrant, .refreshTokenReuseDetected, .notAuthenticated:
            return true
        case .networkUnavailable, .providerRejected:
            return false
        }
    }
}
