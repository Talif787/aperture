import Testing
import Foundation
@testable import ApertureSync
import ApertureDomain
import ApertureTestSupport

@Suite("Retry policy")
struct RetryPolicyTests {

    @Test("the jitter window doubles until it reaches the ceiling")
    func ceilingGrowsExponentiallyThenClamps() {
        let policy = RetryPolicy.standard

        #expect(policy.delayCeiling(forAttempt: 0) == 2)
        #expect(policy.delayCeiling(forAttempt: 1) == 4)
        #expect(policy.delayCeiling(forAttempt: 2) == 8)
        #expect(policy.delayCeiling(forAttempt: 9) == 900)
        #expect(policy.delayCeiling(forAttempt: 40) == 900)
    }

    @Test("full jitter draws from the whole window, not just its upper half")
    func fullJitterCoversTheWholeWindow() {
        let policy = RetryPolicy.standard
        let random = SeededRandomSource(seed: 2026)

        let samples = (0..<400).map { _ in policy.delay(forAttempt: 6, random: random) }
        let ceiling = policy.delayCeiling(forAttempt: 6)

        #expect(samples.allSatisfy { $0 >= 0 && $0 <= ceiling })
        // The property that matters for a fleet reconnecting at once: a meaningful share
        // of the draws must land in the lower half of the window. Equal jitter would put
        // every draw above ceiling/2 and re-correlate the herd.
        let lowerHalf = samples.filter { $0 < ceiling / 2 }
        #expect(lowerHalf.count > samples.count / 4)
    }

    @Test("stops retrying at the configured attempt limit")
    func respectsAttemptLimit() {
        let policy = RetryPolicy.standard

        #expect(policy.shouldRetry(afterAttemptCount: 11))
        #expect(policy.shouldRetry(afterAttemptCount: 12) == false)
    }

    @Test("delays are reproducible for a given seed")
    func reproducibleSchedule() {
        let policy = RetryPolicy.standard

        let first = (0..<12).map { policy.delay(forAttempt: $0, random: SeededRandomSource(seed: 1)) }
        let second = (0..<12).map { policy.delay(forAttempt: $0, random: SeededRandomSource(seed: 1)) }

        #expect(first == second)
    }

    @Test("twelve attempts span roughly a day in the worst case")
    func worstCaseSpanIsAboutTwentyFourHours() {
        let policy = RetryPolicy.standard

        let worstCase = (0..<policy.maximumAttempts)
            .map { policy.delayCeiling(forAttempt: $0) }
            .reduce(0, +)

        #expect(worstCase > 3600)
        #expect(worstCase < 86_400)
    }
}

@Suite("Sync operation state machine")
struct SyncOperationStateTests {

    @Test("permits only the transitions the queue actually performs")
    func legalTransitions() {
        #expect(SyncOperationState.pending.canTransition(to: .inFlight))
        #expect(SyncOperationState.inFlight.canTransition(to: .pending))
        #expect(SyncOperationState.inFlight.canTransition(to: .failed))
        #expect(SyncOperationState.failed.canTransition(to: .pending))
        #expect(SyncOperationState.failed.canTransition(to: .dead))
    }

    @Test("rejects transitions that would resurrect or skip states")
    func illegalTransitions() {
        #expect(SyncOperationState.dead.canTransition(to: .pending) == false)
        #expect(SyncOperationState.pending.canTransition(to: .failed) == false)
        #expect(SyncOperationState.pending.canTransition(to: .dead) == false)
    }

    @Test("only pending operations are dispatched")
    func dispatchEligibility() {
        #expect(SyncOperationState.pending.isEligibleForDispatch)
        #expect(SyncOperationState.inFlight.isEligibleForDispatch == false)
        #expect(SyncOperationState.dead.requiresUserAttention)
    }

    @Test("operation kinds round-trip through their wire values")
    func kindWireValues() {
        #expect(SyncOperationKind.attachMedia.rawValue == "attach_media")
        #expect(SyncOperationKind(rawValue: "resolve_conflict") == .resolveConflict)
        #expect(SyncOperationKind.allCases.count == 6)
    }
}
