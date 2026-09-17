import Foundation

/// What the application should do with the session right now.
public enum SessionDisposition: Equatable, Sendable {
    /// The access token is usable.
    case proceed

    /// Expired, but the network is available and the refresh token is good.
    case refreshRequired

    /// Expired with no way to refresh, and still inside the grace window.
    ///
    /// The distinguishing state of this product. Capture, analysis, form entry, and local
    /// reporting all continue; only synchronization pauses. Locking an inspector out of
    /// their own work because a token expired in a crawl space would be a total failure of
    /// the premise.
    case offlineGrace(expiresAt: Date)

    /// The user must sign in again before the session can continue.
    ///
    /// Note what this does not mean: work captured on this device stays readable and
    /// exportable regardless. A version gate or an expired session never strands a user's
    /// own data.
    case reauthenticationRequired(reason: Reason)

    public enum Reason: String, Equatable, Sendable {
        case noCredentials
        case refreshTokenExpired
        case graceWindowElapsed
        case credentialsRevoked
    }
}

/// Decides the session disposition from state alone.
///
/// A pure function of its inputs, deliberately. The policy is the part with the subtle
/// rules, so it is separated from the machinery that acts on it and can be exhaustively
/// tested without a network, a keychain, or a clock that actually moves.
public struct SessionPolicy: Sendable, Equatable {
    /// How long work continues after the credentials stop being refreshable.
    ///
    /// 72 hours, matching the supported offline working window. A utility inspector on a
    /// rural route can be dark for an entire long weekend, and the session must outlive it.
    public let gracePeriod: TimeInterval
    public let clockSkew: TimeInterval

    public static let standard = SessionPolicy(gracePeriod: 72 * 60 * 60, clockSkew: 60)

    public init(gracePeriod: TimeInterval, clockSkew: TimeInterval) {
        precondition(gracePeriod > 0, "a grace period is required")
        self.gracePeriod = gracePeriod
        self.clockSkew = clockSkew
    }

    public func disposition(
        tokens: TokenPair?,
        isNetworkAvailable: Bool,
        now: Date
    ) -> SessionDisposition {
        guard let tokens else {
            return .reauthenticationRequired(reason: .noCredentials)
        }

        if tokens.isAccessTokenUsable(at: now, skew: clockSkew) {
            return .proceed
        }

        guard tokens.isRefreshTokenUsable(at: now) else {
            return .reauthenticationRequired(reason: .refreshTokenExpired)
        }

        if isNetworkAvailable {
            return .refreshRequired
        }

        // Grace runs from the moment the access token lapsed, not from the last successful
        // refresh. Measuring from the refresh would silently shorten the window by the
        // token's own lifetime, and a 72 hour promise that delivers 71 hours 45 minutes is
        // a promise that fails on the last morning of a long route.
        let graceExpiry = tokens.accessTokenExpiry.addingTimeInterval(gracePeriod)

        guard now < graceExpiry else {
            return .reauthenticationRequired(reason: .graceWindowElapsed)
        }

        return .offlineGrace(expiresAt: graceExpiry)
    }

    /// Whether capture and local editing remain available.
    ///
    /// True in every disposition. Stated as an explicit function rather than left implicit
    /// because it is the rule most likely to be violated by a well-meaning change: the
    /// natural instinct when a session expires is to gate the interface, and here that
    /// instinct is wrong.
    public func permitsLocalWork(for disposition: SessionDisposition) -> Bool {
        true
    }

    /// Whether the sync engine should attempt to reach the server.
    public func permitsSynchronization(for disposition: SessionDisposition) -> Bool {
        disposition == .proceed
    }
}
