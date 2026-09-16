import Testing
import Foundation
@testable import ApertureDomain
import ApertureTestSupport

@Suite("Hybrid logical clock")
struct HybridLogicalClockTests {

    private func generator(
        nodeID: String = "devA",
        clock: TestDateProvider = TestDateProvider()
    ) -> (HybridLogicalClockGenerator, TestDateProvider) {
        (HybridLogicalClockGenerator(nodeID: nodeID, dateProvider: clock), clock)
    }

    @Test("every issued value is strictly greater than the one before it")
    func sendIsMonotonic() {
        let (generator, _) = generator()

        let values = (0..<500).map { _ in generator.send() }

        for index in 1..<values.count {
            #expect(values[index - 1] < values[index])
        }
    }

    @Test("ordering survives a clock that does not move")
    func monotonicWithFrozenPhysicalClock() {
        let (generator, _) = generator()

        // The provider never advances, so wall-clock time is identical for all of these.
        let first = generator.send()
        let second = generator.send()
        let third = generator.send()

        #expect(first.wallClockMilliseconds == second.wallClockMilliseconds)
        #expect(first < second)
        #expect(second < third)
        #expect(second.counter == first.counter + 1)
    }

    @Test("ordering survives a clock that runs backwards")
    func monotonicWhenPhysicalClockGoesBackwards() {
        let (generator, dateProvider) = generator()

        let before = generator.send()
        // The user changes the device time, or a time zone update lands. This is the case
        // that makes wall-clock last-writer-wins unsound, and it is not exotic.
        dateProvider.advance(by: -3600)
        let after = generator.send()

        #expect(before < after)
        #expect(after.wallClockMilliseconds >= before.wallClockMilliseconds)
    }

    @Test("receiving a remote value carries causality forward")
    func receiveAdvancesPastRemote() throws {
        let (local, _) = generator(nodeID: "devA")
        let remoteClock = TestDateProvider()
        remoteClock.advance(by: 5)
        let (remote, _) = generator(nodeID: "devB", clock: remoteClock)

        let remoteValue = remote.send()
        let merged = try local.receive(remoteValue)

        #expect(remoteValue < merged)
        #expect(merged.nodeID == "devA")
    }

    @Test("a later local event is ordered after a merged remote one")
    func sendAfterReceiveIsOrdered() throws {
        let (local, _) = generator(nodeID: "devA")
        let remoteClock = TestDateProvider()
        remoteClock.advance(by: 30)
        let (remote, _) = generator(nodeID: "devB", clock: remoteClock)

        let merged = try local.receive(remote.send())
        let next = local.send()

        #expect(merged < next)
    }

    @Test("two nodes stamping the same millisecond still order deterministically")
    func nodeIdentityBreaksTies() {
        let shared = TestDateProvider()
        let alpha = HybridLogicalClockGenerator(nodeID: "devA", dateProvider: shared).send()
        let beta = HybridLogicalClockGenerator(nodeID: "devB", dateProvider: shared).send()

        #expect(alpha.wallClockMilliseconds == beta.wallClockMilliseconds)
        #expect(alpha.counter == beta.counter)
        // Without the node tiebreaker these would compare equal, and conflict resolution
        // would produce different answers on different replicas from identical inputs.
        #expect(alpha < beta)
        #expect((beta < alpha) == false)
    }

    @Test("a remote value far in the future is rejected rather than adopted")
    func excessiveDriftIsRejected() {
        let (local, _) = generator()
        let farFuture = HybridLogicalClock(
            wallClockMilliseconds: UInt64(Date(timeIntervalSince1970: 1_780_000_000).timeIntervalSince1970 * 1000)
                + (48 * 60 * 60 * 1000),
            counter: 0,
            nodeID: "devWrong"
        )

        #expect(throws: HybridLogicalClockError.self) {
            _ = try local.receive(farFuture)
        }
    }

    @Test("a remote value inside the drift limit is accepted")
    func toleratesReasonableSkew() throws {
        let (local, _) = generator()
        let slightlyAhead = HybridLogicalClock(
            wallClockMilliseconds: UInt64(Date(timeIntervalSince1970: 1_780_000_000).timeIntervalSince1970 * 1000)
                + (10 * 60 * 1000),
            counter: 3,
            nodeID: "devB"
        )

        let merged = try local.receive(slightlyAhead)

        #expect(slightlyAhead < merged)
    }

    @Test("rejecting drift leaves the local clock untouched")
    func rejectedDriftDoesNotPoisonLocalState() {
        let (local, _) = generator()
        let before = local.send()

        let farFuture = HybridLogicalClock(
            wallClockMilliseconds: before.wallClockMilliseconds + (72 * 60 * 60 * 1000),
            counter: 0,
            nodeID: "devWrong"
        )
        _ = try? local.receive(farFuture)

        let after = local.send()

        // If the rejected value had been adopted, this would have jumped three days.
        #expect(after.wallClockMilliseconds < before.wallClockMilliseconds + 1000)
    }

    @Test("two replicas converge on the same order from the same events", arguments: [1, 7, 42, 1_009])
    func convergentOrderingUnderInterleaving(seed: UInt64) throws {
        // A small generative check: interleave local and remote events in a random order
        // and assert that sorting the resulting stamps produces the same sequence on both
        // sides. This is the property the whole conflict design rests on, and it is
        // exercised properly by the Phase 5 convergence suite.
        let random = SeededRandomSource(seed: seed)
        let sharedClock = TestDateProvider()
        let alpha = HybridLogicalClockGenerator(nodeID: "devA", dateProvider: sharedClock)
        let beta = HybridLogicalClockGenerator(nodeID: "devB", dateProvider: sharedClock)

        var stamps: [HybridLogicalClock] = []

        for _ in 0..<200 {
            if random.value(upperBound: 3) == 0 {
                sharedClock.advance(by: 0.001)
            }
            if random.value(upperBound: 2) == 0 {
                stamps.append(alpha.send())
            } else {
                let value = beta.send()
                stamps.append(try alpha.receive(value))
            }
        }

        let sortedOnce = stamps.sorted()
        let sortedAgain = stamps.shuffled().sorted()

        #expect(sortedOnce == sortedAgain)
        #expect(Set(stamps).count == stamps.count, "no two events share a stamp")
    }

    @Test("the wire form round-trips through Codable")
    func codableRoundTrip() throws {
        let original = HybridLogicalClock(wallClockMilliseconds: 1_789_000_000_123, counter: 42, nodeID: "devA")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HybridLogicalClock.self, from: data)

        #expect(decoded == original)
    }

    @Test("the description is an exact, locale-independent wire format")
    func descriptionFormat() {
        let clock = HybridLogicalClock(wallClockMilliseconds: 1_789_000_000_123, counter: 42, nodeID: "devA")

        #expect(clock.description == "2026-09-10T00:26:40.123Z-0042-devA")
    }

    @Test(
        "date arithmetic is exact across the epoch, leap years, and century boundaries",
        arguments: [
            (UInt64(0), "1970-01-01T00:00:00.000Z"),
            (UInt64(1_000), "1970-01-01T00:00:01.000Z"),
            (UInt64(1_735_689_599_999), "2024-12-31T23:59:59.999Z"),
            (UInt64(1_780_000_000_000), "2026-05-28T20:26:40.000Z"),
            (UInt64(4_102_444_800_000), "2100-01-01T00:00:00.000Z")
        ]
    )
    func civilDateConversion(milliseconds: UInt64, expected: String) {
        // 2100 is not a leap year despite being divisible by four, which is the case a
        // naive day-count conversion gets wrong.
        let clock = HybridLogicalClock(wallClockMilliseconds: milliseconds, counter: 0, nodeID: "n")

        #expect(clock.description == "\(expected)-0000-n")
    }
}
