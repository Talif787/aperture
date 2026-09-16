import Foundation
import ApertureDomain

/// A clock the test controls.
///
/// Without this, a backoff test either sleeps for real or is never written, and which of
/// those happens decides whether the retry logic is ever actually verified.
public final class TestDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
        self.current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Moves time forward. Tests assert on schedules, never on elapsed real time.
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(to instant: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = instant
    }
}

/// A seeded, reproducible random source.
///
/// Uses SplitMix64, which is short enough to read in one sitting and produces identical
/// sequences on every platform. Reproducibility matters more than statistical quality
/// here: a generative test that fails must be replayable from its seed.
public final class SeededRandomSource: RandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    private func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public func bytes(count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var output = [UInt8]()
        output.reserveCapacity(count)
        while output.count < count {
            let word = next()
            for shift in stride(from: 0, to: 64, by: 8) where output.count < count {
                output.append(UInt8((word >> UInt64(shift)) & 0xFF))
            }
        }
        return output
    }

    public func value(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be greater than zero")
        lock.lock()
        defer { lock.unlock() }
        return next() % upperBound
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
