import Testing
import Foundation
@testable import ApertureAuth
import ApertureDomain
import ApertureTestSupport

@Suite("Token refresh coordination")
struct TokenRefreshCoordinatorTests {

    private let issuedAt = Date(timeIntervalSince1970: 1_780_000_000)

    private func expiredTokens() -> TokenPair {
        TokenPair(
            accessToken: "stale",
            accessTokenExpiry: issuedAt.addingTimeInterval(-60),
            refreshToken: "refresh-0",
            refreshTokenExpiry: issuedAt.addingTimeInterval(30 * 24 * 60 * 60),
            issuedAt: issuedAt
        )
    }

    private func makeCoordinator(
        store: InMemoryTokenStore,
        refresher: CountingTokenRefresher
    ) -> TokenRefreshCoordinator {
        let dateProvider = TestDateProvider(start: issuedAt)
        return TokenRefreshCoordinator(
            store: store,
            refresher: refresher,
            dateProvider: dateProvider
        )
    }

    @Test("a live access token is returned without a network exchange")
    func liveTokenSkipsRefresh() async throws {
        let live = TokenPair(
            accessToken: "live",
            accessTokenExpiry: issuedAt.addingTimeInterval(600),
            refreshToken: "refresh-0",
            refreshTokenExpiry: issuedAt.addingTimeInterval(30 * 24 * 60 * 60),
            issuedAt: issuedAt
        )
        let store = InMemoryTokenStore(initial: live)
        let refresher = CountingTokenRefresher()
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        let token = try await coordinator.validAccessToken()

        #expect(token == "live")
        #expect(refresher.callCount == 0)
    }

    @Test("an expired token triggers exactly one refresh")
    func singleRefresh() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher()
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        let token = try await coordinator.validAccessToken()

        #expect(token == "access-1")
        #expect(refresher.callCount == 1)
        #expect(store.current?.refreshToken == "refresh-1")
    }

    @Test("twenty concurrent callers produce one refresh, not twenty")
    func concurrentCallersCoalesce() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(delay: .milliseconds(40))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await coordinator.validAccessToken() }
            }
            var collected: [String] = []
            for try await token in group {
                collected.append(token)
            }
            return collected
        }

        // This is the assertion the type exists for. Without coalescing, the second caller
        // presents a refresh token the first already consumed, the provider reads that as a
        // replay, and it revokes the whole family: the user is signed out mid-shift by a
        // race that never reproduces on a fast desk network.
        #expect(refresher.callCount == 1)
        #expect(tokens.count == 20)
        #expect(Set(tokens) == ["access-1"])
    }

    @Test("a consumed refresh token is never presented twice")
    func rotatingTokenIsNotReused() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(delay: .milliseconds(30))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await coordinator.validAccessToken() }
            }
            // `!= nil` rather than `let _ =`: binding a value only to discard it says the
            // value matters when only its presence does.
            while (try? await group.next()) != nil {}
        }

        #expect(refresher.presentedTokens == ["refresh-0"])
        #expect(Set(refresher.presentedTokens).count == refresher.presentedTokens.count)
    }

    @Test("a second refresh after the first completes is a new exchange")
    func sequentialRefreshesAreNotCoalesced() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(delay: .milliseconds(1))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        _ = try await coordinator.forceRefresh()
        _ = try await coordinator.forceRefresh()

        // Coalescing is scoped to a single in-flight window. Two genuinely separate
        // refreshes must both happen, or a token that expires twice would only refresh once.
        #expect(refresher.callCount == 2)
        #expect(refresher.presentedTokens == ["refresh-0", "refresh-1"])
    }

    @Test("a rejected refresh clears the credentials")
    func invalidGrantClearsState() async {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(behavior: .fail(.invalidGrant))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        await #expect(throws: AuthError.self) {
            _ = try await coordinator.validAccessToken()
        }

        // Leaving dead credentials in place would make every subsequent call re-present a
        // token the provider has already rejected, which looks like an attack from the
        // other side.
        #expect(store.current == nil)
        #expect(store.clearCount == 1)
    }

    @Test("detected reuse clears the credentials")
    func reuseDetectionIsTerminal() async {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(behavior: .fail(.refreshTokenReuseDetected))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        await #expect(throws: AuthError.self) {
            _ = try await coordinator.validAccessToken()
        }

        #expect(store.current == nil)
    }

    @Test("a network failure preserves the credentials")
    func networkFailureIsNotTerminal() async {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(behavior: .fail(.networkUnavailable))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        await #expect(throws: AuthError.self) {
            _ = try await coordinator.validAccessToken()
        }

        // The outcome is unknown, not failed. Discarding credentials here would sign a user
        // out every time they walked into a basement.
        #expect(store.current != nil)
        #expect(store.clearCount == 0)
    }

    @Test("a failed refresh does not wedge the coordinator")
    func recoveryAfterFailure() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let refresher = CountingTokenRefresher(behavior: .fail(.networkUnavailable), delay: .milliseconds(1))
        let coordinator = makeCoordinator(store: store, refresher: refresher)

        _ = try? await coordinator.validAccessToken()
        refresher.setBehavior(.succeed)

        // If the in-flight task were not cleared on failure, every later caller would await
        // a task that already threw, and the session would never recover without a restart.
        let token = try await coordinator.validAccessToken()

        #expect(token == "access-2")
    }

    @Test("signing out clears storage")
    func signOut() async throws {
        let store = InMemoryTokenStore(initial: expiredTokens())
        let coordinator = makeCoordinator(store: store, refresher: CountingTokenRefresher())

        try await coordinator.signOut()

        #expect(store.current == nil)
    }

    @Test("an unauthenticated coordinator reports it rather than refreshing")
    func noCredentials() async {
        let coordinator = makeCoordinator(
            store: InMemoryTokenStore(initial: nil),
            refresher: CountingTokenRefresher()
        )

        await #expect(throws: AuthError.notAuthenticated) {
            _ = try await coordinator.validAccessToken()
        }
    }
}

@Suite("Token state")
struct TokenStateTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test("expiry judgment includes a skew allowance")
    func skewAllowance() {
        let pair = TokenPair(
            accessToken: "a",
            accessTokenExpiry: now.addingTimeInterval(45),
            refreshToken: "r",
            refreshTokenExpiry: now.addingTimeInterval(1000),
            issuedAt: now
        )

        #expect(pair.isAccessTokenUsable(at: now, skew: 60) == false)
        #expect(pair.isAccessTokenUsable(at: now, skew: 0))
    }

    @Test("terminal and recoverable failures are distinguished")
    func errorClassification() {
        #expect(AuthError.invalidGrant.isTerminal)
        #expect(AuthError.refreshTokenReuseDetected.isTerminal)
        #expect(AuthError.notAuthenticated.isTerminal)
        #expect(AuthError.networkUnavailable.isTerminal == false)
        #expect(AuthError.providerRejected(code: "temporarily_unavailable").isTerminal == false)
    }
}
