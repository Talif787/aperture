import Foundation
import ApertureDomain

/// Backoff schedule for queued sync operations.
///
/// Full jitter, not equal jitter and not fixed backoff. The reason is specific to this
/// product rather than general good practice: the dominant reconnection pattern is
/// thousands of devices regaining connectivity inside the same half-hour window at shift
/// end. Correlated retries across that fleet would be a self-inflicted denial of service
/// against the sync endpoint, so the delay is drawn uniformly from the whole interval
/// rather than from the top half of it.
///
///     delay = random(0, min(cap, base * 2^attempt))
public struct RetryPolicy: Sendable, Equatable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let maximumAttempts: Int

    /// Production defaults: 2 second base, 15 minute ceiling, 12 attempts spanning
    /// roughly 24 hours before an operation is dead-lettered and surfaced to the user.
    public static let standard = RetryPolicy(
        baseDelay: 2,
        maximumDelay: 900,
        maximumAttempts: 12
    )

    public init(baseDelay: TimeInterval, maximumDelay: TimeInterval, maximumAttempts: Int) {
        precondition(baseDelay > 0, "base delay must be positive")
        precondition(maximumDelay >= baseDelay, "ceiling must not be below the base delay")
        precondition(maximumAttempts > 0, "at least one attempt must be permitted")
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
    }

    /// The upper bound of the jitter window for a zero-based attempt number.
    /// Exposed separately from `delay(forAttempt:random:)` so tests can assert the
    /// envelope without depending on a particular random draw.
    public func delayCeiling(forAttempt attempt: Int) -> TimeInterval {
        precondition(attempt >= 0, "attempt number must not be negative")
        // Cap the shift before it is applied. 2^63 overflows, and an exponent that large
        // is meaningless once the ceiling has been reached anyway.
        let exponent = min(attempt, 32)
        let uncapped = baseDelay * pow(2, Double(exponent))
        return min(uncapped, maximumDelay)
    }

    /// The delay before the next attempt, drawn uniformly from `0...ceiling`.
    public func delay(forAttempt attempt: Int, random: any RandomSource) -> TimeInterval {
        let ceiling = delayCeiling(forAttempt: attempt)
        // Millisecond resolution is more than adequate and keeps the draw in integer space.
        let milliseconds = UInt64(ceiling * 1000)
        guard milliseconds > 0 else { return 0 }
        return TimeInterval(random.value(upperBound: milliseconds + 1)) / 1000
    }

    /// Whether another attempt is permitted after `attemptCount` failures.
    public func shouldRetry(afterAttemptCount attemptCount: Int) -> Bool {
        attemptCount < maximumAttempts
    }
}
