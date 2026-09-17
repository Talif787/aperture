import Foundation
import Synchronization
import ApertureAuth

/// An in-memory token store.
public final class InMemoryTokenStore: TokenStore, Sendable {
    private struct Storage {
        var tokens: TokenPair?
        var saveCount: Int = 0
        var clearCount: Int = 0
    }

    private let storage: Mutex<Storage>

    public init(initial: TokenPair? = nil) {
        self.storage = Mutex(Storage(tokens: initial))
    }

    public var saveCount: Int { storage.withLock { $0.saveCount } }
    public var clearCount: Int { storage.withLock { $0.clearCount } }
    public var current: TokenPair? { storage.withLock { $0.tokens } }

    public func load() async throws -> TokenPair? {
        storage.withLock { $0.tokens }
    }

    public func save(_ tokens: TokenPair) async throws {
        storage.withLock { current in
            current.tokens = tokens
            current.saveCount += 1
        }
    }

    public func clear() async throws {
        storage.withLock { current in
            current.tokens = nil
            current.clearCount += 1
        }
    }
}

/// A refresher that counts invocations and can be made slow or failing.
///
/// The call count is the whole point: the property worth proving about refresh is that
/// twenty concurrent callers produce exactly one network exchange, and only a counting
/// double can demonstrate that.
public final class CountingTokenRefresher: TokenRefreshing, Sendable {
    public enum Behavior: Sendable {
        case succeed
        case fail(AuthError)
    }

    private struct Storage {
        var callCount: Int = 0
        var behavior: Behavior
        var presentedTokens: [String] = []
    }

    private let storage: Mutex<Storage>
    private let delay: Duration
    private let issuedAt: Date
    private let accessLifetime: TimeInterval
    private let refreshLifetime: TimeInterval

    public init(
        behavior: Behavior = .succeed,
        delay: Duration = .milliseconds(20),
        issuedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        accessLifetime: TimeInterval = 15 * 60,
        refreshLifetime: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.storage = Mutex(Storage(behavior: behavior))
        self.delay = delay
        self.issuedAt = issuedAt
        self.accessLifetime = accessLifetime
        self.refreshLifetime = refreshLifetime
    }

    public var callCount: Int { storage.withLock { $0.callCount } }

    /// Every refresh token presented, in order. Used to prove that a consumed token is
    /// never presented twice.
    public var presentedTokens: [String] { storage.withLock { $0.presentedTokens } }

    public func setBehavior(_ behavior: Behavior) {
        storage.withLock { $0.behavior = behavior }
    }

    public func refresh(using refreshToken: String) async throws -> TokenPair {
        let behavior = storage.withLock { current -> Behavior in
            current.callCount += 1
            current.presentedTokens.append(refreshToken)
            return current.behavior
        }

        // A real exchange takes time, and the race this type exists to expose only appears
        // when the window is open long enough for a second caller to arrive.
        try? await Task.sleep(for: delay)

        switch behavior {
        case .fail(let error):
            throw error
        case .succeed:
            let sequence = callCount
            return TokenPair(
                accessToken: "access-\(sequence)",
                accessTokenExpiry: issuedAt.addingTimeInterval(accessLifetime),
                // Rotating: each exchange issues a new refresh token and invalidates the
                // one presented.
                refreshToken: "refresh-\(sequence)",
                refreshTokenExpiry: issuedAt.addingTimeInterval(refreshLifetime),
                issuedAt: issuedAt
            )
        }
    }
}
