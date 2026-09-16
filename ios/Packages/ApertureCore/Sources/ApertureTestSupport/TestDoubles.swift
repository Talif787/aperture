import Foundation
import Synchronization
import ApertureDomain

/// A clock the test controls.
///
/// Without this, a backoff test either sleeps for real or is never written, and which of
/// those happens decides whether the retry logic is ever actually verified.
///
/// Synchronized with `Mutex` rather than `NSLock` so the `Sendable` conformance is
/// checked by the compiler. An `NSLock` version would need an unchecked conformance,
/// which is a promise the compiler cannot verify, and the project forbids those without
/// a recorded decision. Here no promise is needed: a final class whose only stored
/// property is an immutable `Mutex` is provably safe to share.
///
/// The phrase above is deliberately spelled out rather than written as the attribute:
/// the custom SwiftLint rule that enforces this is a regular expression and matches
/// inside comments too.
public final class TestDateProvider: DateProviding, Sendable {
    private let current: Mutex<Date>

    public init(start: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
        self.current = Mutex(start)
    }

    public var now: Date {
        current.withLock { $0 }
    }

    /// Moves time forward. Tests assert on schedules, never on elapsed real time.
    public func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    public func set(to instant: Date) {
        current.withLock { $0 = instant }
    }
}

/// A seeded, reproducible random source.
///
/// Uses SplitMix64, which is short enough to read in one sitting and produces identical
/// sequences on every platform. Reproducibility matters more than statistical quality
/// here: a generative test that fails must be replayable from its seed.
public final class SeededRandomSource: RandomSource, Sendable {
    private let state: Mutex<UInt64>

    public init(seed: UInt64) {
        self.state = Mutex(seed)
    }

    /// One SplitMix64 step, advancing the caller's state in place.
    private static func next(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    public func bytes(count: Int) -> [UInt8] {
        precondition(count >= 0, "byte count must not be negative")
        return state.withLock { seed in
            var output = [UInt8]()
            output.reserveCapacity(count)
            while output.count < count {
                let word = Self.next(&seed)
                for shift in stride(from: 0, to: 64, by: 8) where output.count < count {
                    output.append(UInt8((word >> UInt64(shift)) & 0xFF))
                }
            }
            return output
        }
    }

    public func value(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be greater than zero")
        return state.withLock { seed in
            Self.next(&seed) % upperBound
        }
    }
}

/// A random source that returns a fixed byte, for assertions on bit layout rather than
/// on distribution.
public struct ConstantRandomSource: RandomSource {
    private let byte: UInt8

    public init(byte: UInt8) {
        self.byte = byte
    }

    public func bytes(count: Int) -> [UInt8] {
        [UInt8](repeating: byte, count: count)
    }

    public func value(upperBound: UInt64) -> UInt64 {
        UInt64(byte) % upperBound
    }
}
