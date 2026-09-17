import Testing
import Foundation
@testable import ApertureAuth

@Suite("Session policy")
struct SessionPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func tokens(
        accessExpiresIn accessOffset: TimeInterval,
        refreshExpiresIn refreshOffset: TimeInterval = 30 * 24 * 60 * 60
    ) -> TokenPair {
        TokenPair(
            accessToken: "access",
            accessTokenExpiry: now.addingTimeInterval(accessOffset),
            refreshToken: "refresh",
            refreshTokenExpiry: now.addingTimeInterval(refreshOffset),
            issuedAt: now
        )
    }

    @Test("a valid access token proceeds")
    func validTokenProceeds() {
        let disposition = SessionPolicy.standard.disposition(
            tokens: tokens(accessExpiresIn: 600),
            isNetworkAvailable: true,
            now: now
        )

        #expect(disposition == .proceed)
    }

    @Test("a token expiring inside the skew window is treated as already expired")
    func skewAllowance() {
        // A token with thirty seconds left will very likely expire before a request on a
        // marginal link arrives. Treating it as live produces a steady trickle of 401s that
        // each cost a round trip to discover.
        let disposition = SessionPolicy.standard.disposition(
            tokens: tokens(accessExpiresIn: 30),
            isNetworkAvailable: true,
            now: now
        )

        #expect(disposition == .refreshRequired)
    }

    @Test("expired with a network available asks for a refresh")
    func expiredOnlineRefreshes() {
        let disposition = SessionPolicy.standard.disposition(
            tokens: tokens(accessExpiresIn: -60),
            isNetworkAvailable: true,
            now: now
        )

        #expect(disposition == .refreshRequired)
    }

    @Test("expired with no network enters grace rather than signing the user out")
    func expiredOfflineEntersGrace() {
        let expired = tokens(accessExpiresIn: -60)

        let disposition = SessionPolicy.standard.disposition(
            tokens: expired,
            isNetworkAvailable: false,
            now: now
        )

        // The defining behavior of this product. An inspector in a crawl space must not be
        // locked out of their own work because a token lapsed.
        #expect(disposition == .offlineGrace(expiresAt: expired.accessTokenExpiry.addingTimeInterval(72 * 60 * 60)))
    }

    @Test("grace is measured from expiry, not from the last refresh")
    func graceStartsAtExpiry() {
        let expired = tokens(accessExpiresIn: -60)
        let policy = SessionPolicy.standard

        guard case .offlineGrace(let expiresAt) = policy.disposition(
            tokens: expired, isNetworkAvailable: false, now: now
        ) else {
            Issue.record("expected grace")
            return
        }

        // Measuring from issuance would silently shorten the window by the access token's
        // own lifetime, and a 72 hour promise that delivers 71 hours 45 minutes fails on
        // the last morning of a long route.
        #expect(expiresAt.timeIntervalSince(expired.accessTokenExpiry) == 72 * 60 * 60)
        #expect(expiresAt > now.addingTimeInterval(71 * 60 * 60))
    }

    @Test("past the grace window, reauthentication is required")
    func graceElapses() {
        let longExpired = tokens(accessExpiresIn: -(73 * 60 * 60))

        let disposition = SessionPolicy.standard.disposition(
            tokens: longExpired,
            isNetworkAvailable: false,
            now: now
        )

        #expect(disposition == .reauthenticationRequired(reason: .graceWindowElapsed))
    }

    @Test("an expired refresh token cannot be saved by grace")
    func expiredRefreshTokenIsTerminal() {
        let dead = tokens(accessExpiresIn: -60, refreshExpiresIn: -1)

        let disposition = SessionPolicy.standard.disposition(
            tokens: dead,
            isNetworkAvailable: false,
            now: now
        )

        #expect(disposition == .reauthenticationRequired(reason: .refreshTokenExpired))
    }

    @Test("no credentials means reauthentication")
    func noCredentials() {
        let disposition = SessionPolicy.standard.disposition(
            tokens: nil,
            isNetworkAvailable: true,
            now: now
        )

        #expect(disposition == .reauthenticationRequired(reason: .noCredentials))
    }

    @Test("local work is permitted in every disposition")
    func localWorkAlwaysPermitted() {
        let policy = SessionPolicy.standard
        let dispositions: [SessionDisposition] = [
            .proceed,
            .refreshRequired,
            .offlineGrace(expiresAt: now),
            .reauthenticationRequired(reason: .graceWindowElapsed),
            .reauthenticationRequired(reason: .noCredentials)
        ]

        // Asserted explicitly because it is the rule most likely to be broken by a
        // well-meaning change. The instinct when a session expires is to gate the
        // interface, and here that instinct is wrong.
        for disposition in dispositions {
            #expect(policy.permitsLocalWork(for: disposition), "\(disposition) must still permit capture")
        }
    }

    @Test("synchronization is permitted only with a live session")
    func syncRequiresAuthentication() {
        let policy = SessionPolicy.standard

        #expect(policy.permitsSynchronization(for: .proceed))
        #expect(policy.permitsSynchronization(for: .offlineGrace(expiresAt: now)) == false)
        #expect(policy.permitsSynchronization(for: .refreshRequired) == false)
    }
}
