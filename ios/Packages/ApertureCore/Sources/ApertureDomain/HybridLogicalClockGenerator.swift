import Foundation
import Synchronization

/// Issues and merges hybrid logical clock values for one node.
///
/// Every mutation in the system passes through `send()`, and every value arriving from
/// another node passes through `receive(_:)`. Those two operations are the entire
/// protocol, and keeping them in one type is deliberate: an implementation scattered
/// across call sites is one where a single missed merge silently breaks causality.
///
/// Synchronized with `Mutex` so the `Sendable` conformance is checked by the compiler
/// rather than asserted. The sync engine, the capture pipeline, and the reconciler all
/// stamp clocks from different isolation domains.
public final class HybridLogicalClockGenerator: Sendable {
    /// How far ahead of this device a remote value may claim to be before it is rejected.
    ///
    /// One hour. Large enough to absorb a genuinely wrong device clock, a daylight saving
    /// mistake, or a slow round trip, and small enough that a single badly configured
    /// device cannot drag a tenant's clock a decade into the future.
    public static let defaultMaximumDrift: UInt64 = 60 * 60 * 1000

    private let nodeID: String
    private let dateProvider: any DateProviding
    private let maximumDrift: UInt64
    private let state: Mutex<HybridLogicalClock>

    public init(
        nodeID: String,
        dateProvider: any DateProviding,
        maximumDrift: UInt64 = HybridLogicalClockGenerator.defaultMaximumDrift
    ) {
        precondition(nodeID.isEmpty == false, "a node identifier is required for total ordering")
        self.nodeID = nodeID
        self.dateProvider = dateProvider
        self.maximumDrift = maximumDrift
        self.state = Mutex(HybridLogicalClock.origin(nodeID: nodeID))
    }

    /// The most recent value this generator issued or accepted.
    public var current: HybridLogicalClock {
        state.withLock { $0 }
    }

    /// Stamps a locally originated event.
    ///
    /// The returned value is strictly greater than every value this generator has issued
    /// or accepted, which is the property the whole design rests on.
    public func send() -> HybridLogicalClock {
        state.withLock { last in
            let physical = physicalMilliseconds()
            let wall = max(last.wallClockMilliseconds, physical)

            let counter: UInt32
            if wall == last.wallClockMilliseconds {
                // The physical clock has not advanced past the last stamp, which happens
                // constantly: several mutations inside one millisecond, or a clock that
                // went backwards. The counter carries the ordering instead.
                counter = last.counter &+ 1
            } else {
                counter = 0
            }

            let next = Self.normalized(
                wallClockMilliseconds: wall,
                counter: counter,
                previousCounter: last.counter,
                nodeID: nodeID
            )
            last = next
            return next
        }
    }

    /// Merges a value received from another node and stamps the receive event.
    ///
    /// - Throws: `HybridLogicalClockError.excessiveDrift` when the remote value claims a
    ///   time further ahead than `maximumDrift`. The caller decides what to do; the clock
    ///   refuses to adopt it silently.
    public func receive(_ remote: HybridLogicalClock) throws -> HybridLogicalClock {
        try state.withLock { last in
            let physical = physicalMilliseconds()

            if remote.wallClockMilliseconds > physical,
               remote.wallClockMilliseconds - physical > maximumDrift {
                throw HybridLogicalClockError.excessiveDrift(
                    remoteMilliseconds: remote.wallClockMilliseconds,
                    localMilliseconds: physical,
                    limitMilliseconds: maximumDrift
                )
            }

            let wall = max(last.wallClockMilliseconds, remote.wallClockMilliseconds, physical)

            let counter: UInt32
            switch (wall == last.wallClockMilliseconds, wall == remote.wallClockMilliseconds) {
            case (true, true):
                // Both sides are in the same millisecond: take the higher counter and
                // advance, so the result is strictly after both.
                counter = max(last.counter, remote.counter) &+ 1
            case (true, false):
                counter = last.counter &+ 1
            case (false, true):
                counter = remote.counter &+ 1
            case (false, false):
                // The physical clock moved past both. The counter can safely restart.
                counter = 0
            }

            let next = Self.normalized(
                wallClockMilliseconds: wall,
                counter: counter,
                previousCounter: max(last.counter, remote.counter),
                nodeID: nodeID
            )
            last = next
            return next
        }
    }

    private func physicalMilliseconds() -> UInt64 {
        let interval = dateProvider.now.timeIntervalSince1970
        guard interval > 0 else { return 0 }
        return UInt64(interval * 1000)
    }

    /// Handles counter overflow by borrowing a millisecond.
    ///
    /// A `UInt32` counter allows roughly four billion events inside one millisecond, so
    /// this is not a case anyone reaches in practice. It is handled anyway because the
    /// alternative is a wraparound that silently produces a value ordered *before* its
    /// predecessor, which would break the one guarantee this type makes.
    private static func normalized(
        wallClockMilliseconds: UInt64,
        counter: UInt32,
        previousCounter: UInt32,
        nodeID: String
    ) -> HybridLogicalClock {
        if counter < previousCounter {
            return HybridLogicalClock(
                wallClockMilliseconds: wallClockMilliseconds &+ 1,
                counter: 0,
                nodeID: nodeID
            )
        }
        return HybridLogicalClock(
            wallClockMilliseconds: wallClockMilliseconds,
            counter: counter,
            nodeID: nodeID
        )
    }
}
