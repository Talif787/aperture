import Foundation

/// A source of randomness that can be made deterministic in tests.
///
/// Determinism seam, defined in Phase 0 section 0.17. Retry jitter and identifier
/// generation both depend on randomness, and neither is testable if it reaches for a
/// global generator. A failing fuzz case must be replayable from its seed.
public protocol RandomSource: Sendable {
    /// Returns `count` random bytes.
    func bytes(count: Int) -> [UInt8]

    /// Returns a value in `0..<upperBound`. `upperBound` must be greater than zero.
    func value(upperBound: UInt64) -> UInt64
}

/// The production implementation, backed by the system generator.
public struct SystemRandomSource: RandomSource {
    public init() {}

    public func bytes(count: Int) -> [UInt8] {
        precondition(count >= 0, "byte count must not be negative")
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    public func value(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be greater than zero")
        var generator = SystemRandomNumberGenerator()
        return UInt64.random(in: 0..<upperBound, using: &generator)
    }
}
