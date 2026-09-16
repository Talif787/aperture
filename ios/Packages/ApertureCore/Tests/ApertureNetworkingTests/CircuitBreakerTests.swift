import Testing
import Foundation
@testable import ApertureNetworking
import ApertureDomain
import ApertureTestSupport

@Suite("Circuit breaker")
struct CircuitBreakerTests {

    private func makeBreaker(
        threshold: Int = 3,
        cooldown: TimeInterval = 30
    ) -> (CircuitBreaker, TestDateProvider) {
        let dateProvider = TestDateProvider()
        let breaker = CircuitBreaker(
            failureThreshold: threshold,
            cooldown: cooldown,
            dateProvider: dateProvider
        )
        return (breaker, dateProvider)
    }

    @Test("stays closed below the failure threshold")
    func staysClosedBelowThreshold() {
        let (breaker, _) = makeBreaker(threshold: 3)

        breaker.recordFailure()
        breaker.recordFailure()

        #expect(breaker.state == .closed)
        #expect(breaker.allowsRequest())
    }

    @Test("opens at the threshold and rejects without touching the network")
    func opensAtThreshold() {
        let (breaker, _) = makeBreaker(threshold: 3)

        for _ in 0..<3 { breaker.recordFailure() }

        #expect(breaker.allowsRequest() == false)
        if case .open = breaker.state {} else {
            Issue.record("expected the circuit to be open")
        }
    }

    @Test("a success resets the failure count")
    func successResetsCount() {
        let (breaker, _) = makeBreaker(threshold: 3)

        breaker.recordFailure()
        breaker.recordFailure()
        breaker.recordSuccess()
        breaker.recordFailure()

        #expect(breaker.state == .closed)
    }

    @Test("moves to half-open once the cooling period elapses")
    func coolsToHalfOpen() {
        let (breaker, dateProvider) = makeBreaker(threshold: 2, cooldown: 30)
        breaker.recordFailure()
        breaker.recordFailure()

        dateProvider.advance(by: 31)

        #expect(breaker.state == .halfOpen)
    }

    @Test("half-open admits exactly one probe")
    func halfOpenAdmitsOneProbe() {
        let (breaker, dateProvider) = makeBreaker(threshold: 2, cooldown: 30)
        breaker.recordFailure()
        breaker.recordFailure()
        dateProvider.advance(by: 31)

        // Admitting every caller here is how a recovering backend gets knocked over by
        // the fleet the moment it comes back.
        #expect(breaker.allowsRequest())
        #expect(breaker.allowsRequest() == false)
        #expect(breaker.allowsRequest() == false)
    }

    @Test("a successful probe closes the circuit")
    func successfulProbeCloses() {
        let (breaker, dateProvider) = makeBreaker(threshold: 2, cooldown: 30)
        breaker.recordFailure()
        breaker.recordFailure()
        dateProvider.advance(by: 31)

        #expect(breaker.allowsRequest())
        breaker.recordSuccess()

        #expect(breaker.state == .closed)
        #expect(breaker.allowsRequest())
    }

    @Test("a failed probe restarts the cooling period rather than counting again")
    func failedProbeReopens() {
        let (breaker, dateProvider) = makeBreaker(threshold: 2, cooldown: 30)
        breaker.recordFailure()
        breaker.recordFailure()
        dateProvider.advance(by: 31)
        _ = breaker.allowsRequest()

        breaker.recordFailure()

        #expect(breaker.allowsRequest() == false)
        dateProvider.advance(by: 31)
        #expect(breaker.state == .halfOpen)
    }

    @Test("reset forces the circuit closed")
    func resetOnConnectivityChange() {
        let (breaker, _) = makeBreaker(threshold: 2)
        breaker.recordFailure()
        breaker.recordFailure()

        // A network change invalidates the evidence that opened the circuit: the failures
        // were about a path that no longer exists.
        breaker.reset()

        #expect(breaker.state == .closed)
        #expect(breaker.allowsRequest())
    }
}
