import Foundation
import ApertureDomain

/// Serializes token refresh across the whole application.
///
/// This type exists to prevent one specific and genuinely common production bug.
///
/// When an access token expires, every in-flight request fails with 401 at roughly the
/// same moment. The obvious implementation has each of them refresh. With rotating
/// refresh tokens, the second one presents a token the first already consumed, the
/// identity provider correctly reads that as a replay, and it revokes the entire token
/// family. The user is signed out, mid-shift, with no explanation, and the cause is a race
/// that does not reproduce on a fast desk network where requests rarely overlap.
///
/// An actor is the right tool rather than a lock: the critical section spans an `await`
/// on the network, and a lock held across `await` either deadlocks or is not held at all.
public actor TokenRefreshCoordinator {
    private let store: any TokenStore
    private let refresher: any TokenRefreshing
    private let dateProvider: any DateProviding
    private let telemetry: any Telemetry

    /// The single refresh in progress. Concurrent callers await this rather than starting
    /// their own, which is the entire point of the type.
    private var inFlight: Task<TokenPair, any Error>?

    public init(
        store: any TokenStore,
        refresher: any TokenRefreshing,
        dateProvider: any DateProviding,
        telemetry: any Telemetry = NoOpTelemetry()
    ) {
        self.store = store
        self.refresher = refresher
        self.dateProvider = dateProvider
        self.telemetry = telemetry
    }

    /// Returns a usable access token, refreshing only if necessary.
    ///
    /// Safe to call from any number of concurrent contexts. Exactly one network refresh
    /// occurs regardless of how many callers arrive together.
    public func validAccessToken() async throws -> String {
        guard let tokens = try await store.load() else {
            throw AuthError.notAuthenticated
        }

        if tokens.isAccessTokenUsable(at: dateProvider.now) {
            return tokens.accessToken
        }

        return try await refreshTokens(current: tokens).accessToken
    }

    /// Forces a refresh, used when a request returned 401 despite a token that looked
    /// valid. Still serialized, so a burst of 401s produces one refresh.
    public func forceRefresh() async throws -> TokenPair {
        guard let tokens = try await store.load() else {
            throw AuthError.notAuthenticated
        }
        return try await refreshTokens(current: tokens)
    }

    public func signOut() async throws {
        inFlight?.cancel()
        inFlight = nil
        try await store.clear()
    }

    private func refreshTokens(current: TokenPair) async throws -> TokenPair {
        if let existing = inFlight {
            // Another caller is already refreshing. Awaiting its result is what keeps a
            // rotating refresh token from being consumed twice.
            telemetry.event("auth.refresh_coalesced", attributes: [:])
            return try await existing.value
        }

        guard current.isRefreshTokenUsable(at: dateProvider.now) else {
            throw AuthError.invalidGrant
        }

        let task = Task<TokenPair, any Error> { [store, refresher, telemetry] in
            do {
                let refreshed = try await refresher.refresh(using: current.refreshToken)
                try await store.save(refreshed)
                telemetry.event("auth.refresh_succeeded", attributes: [:])
                return refreshed
            } catch let error as AuthError where error.isTerminal {
                // The credentials are dead. Clearing here rather than leaving them in place
                // stops every subsequent call from re-presenting a token already known to
                // be rejected, which would look like an attack to the provider.
                try? await store.clear()
                telemetry.error(error == .refreshTokenReuseDetected ? "ERR-4703" : "ERR-4702", correlationID: nil)
                throw error
            } catch {
                // A network failure leaves the outcome unknown, so the credentials survive.
                // Discarding them here would sign a user out every time they walked into a
                // basement, which is the opposite of what this product needs.
                telemetry.event("auth.refresh_deferred", attributes: [:])
                throw error
            }
        }

        inFlight = task
        defer { inFlight = nil }

        return try await task.value
    }
}
