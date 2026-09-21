import Foundation
import ApertureDomain

/// A durable record of an intent to change server state.
///
/// The operation is the unit of durability in this system. A mutation is not "saved" when
/// the entity row is written; it is saved when the entity row and this record commit
/// together. Everything the sync engine does is a function of what is in this queue.
public struct SyncOperation: Sendable, Equatable, Identifiable {
    public let id: OperationID
    public let entityType: String
    public let entityID: String
    public let kind: SyncOperationKind

    /// Which fields the local edit touched. Sent with the delta so the server can detect
    /// an overlapping change rather than a merely concurrent one.
    public let dirtyFields: Set<String>

    /// The server version this edit was derived from. A mismatch is how concurrency is
    /// detected at all; without it the server could only offer last-writer-wins.
    public let baseVersion: Int64
    public let hlc: HybridLogicalClock
    public let createdAt: Date

    public private(set) var state: SyncOperationState
    public private(set) var attemptCount: Int
    public private(set) var nextAttemptAt: Date?
    public private(set) var lastErrorCode: String?

    /// The identifier doubles as the idempotency key.
    ///
    /// Minted on the device when the intent is recorded, so a retry after an unknown
    /// outcome carries the same key and the server replays its stored response rather than
    /// applying the effect twice. On a marginal link every request outcome is success,
    /// failure, or unknown, and unknown is the common case.
    public var idempotencyKey: String { id.description }

    public init(
        id: OperationID,
        entityType: String,
        entityID: String,
        kind: SyncOperationKind,
        dirtyFields: Set<String>,
        baseVersion: Int64,
        hlc: HybridLogicalClock,
        createdAt: Date
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.kind = kind
        self.dirtyFields = dirtyFields
        self.baseVersion = baseVersion
        self.hlc = hlc
        self.createdAt = createdAt
        self.state = .pending
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lastErrorCode = nil
    }

    /// Marks the operation dispatched.
    ///
    /// The `inFlight` state is what makes a process death mid-request recoverable. On the
    /// next launch these are re-driven with their original idempotency keys, and the server
    /// replays rather than reapplies. Omitting this state is the most common defect in
    /// offline queues, and it is silent: the loss only appears as a missing or duplicated
    /// server-side effect long after the fact.
    public mutating func markInFlight() {
        guard state.canTransition(to: .inFlight) else { return }
        state = .inFlight
        attemptCount += 1
    }

    /// Records a failure and schedules the next attempt, or gives up.
    public mutating func markFailed(
        code: String,
        policy: RetryPolicy,
        now: Date,
        random: any RandomSource
    ) {
        lastErrorCode = code

        guard policy.shouldRetry(afterAttemptCount: attemptCount) else {
            // Dead-lettered work is a user with a stuck inspection, not a background
            // statistic. It surfaces in the interface with a plain-language reason.
            state = .dead
            nextAttemptAt = nil
            return
        }

        state = .failed
        nextAttemptAt = now.addingTimeInterval(
            policy.delay(forAttempt: attemptCount - 1, random: random)
        )
    }

    /// Returns a failed or interrupted operation to the dispatch pool.
    public mutating func returnToPending() {
        guard state.canTransition(to: .pending) else { return }
        state = .pending
    }

    /// Re-drives an operation abandoned in flight by a terminated process.
    ///
    /// The attempt count is deliberately not incremented. The process died; the server may
    /// never have seen the request. Counting it as a failure would burn a retry the
    /// operation never had.
    public mutating func requeueAfterTermination() {
        guard state == .inFlight else { return }
        state = .pending
        nextAttemptAt = nil
    }

    /// Whether the queue should send this now.
    ///
    /// Pending with no deadline goes immediately. Pending or failed with a deadline waits
    /// for it. In flight never goes, because it may already be with the server. Dead never
    /// goes, because a person has to act first.
    public func isDispatchable(at instant: Date) -> Bool {
        guard state.isEligibleForDispatch else { return false }
        guard let nextAttemptAt else { return true }
        return instant >= nextAttemptAt
    }
}
