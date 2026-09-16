import Foundation

/// Lifecycle of a queued sync operation.
///
/// `inFlight` is not an optimization and not bookkeeping. It is the state that makes a
/// process termination mid-request recoverable: on the next launch, any operation left in
/// `inFlight` is re-driven with its original idempotency key, and the server replays the
/// stored response rather than applying the effect twice. Omitting this state is the most
/// common defect in offline queue implementations, and it is silent, because the failure
/// only appears as duplicated or missing server-side effects long after the fact.
public enum SyncOperationState: String, Sendable, CaseIterable, Codable {
    case pending
    case inFlight
    case failed
    case dead

    /// Transitions permitted by the queue. Anything else is a programming error.
    public func canTransition(to next: SyncOperationState) -> Bool {
        switch (self, next) {
        case (.pending, .inFlight),
             (.inFlight, .failed),
             (.inFlight, .pending),
             (.failed, .pending),
             (.failed, .dead),
             (.inFlight, .dead):
            return true
        default:
            return false
        }
    }

    /// Whether the queue should attempt to send this operation.
    public var isEligibleForDispatch: Bool {
        self == .pending
    }

    /// Whether the operation requires user attention rather than another retry.
    public var requiresUserAttention: Bool {
        self == .dead
    }
}

/// The mutation an operation carries. Kept as a closed set so the server, the client, and
/// the conformance corpus cannot drift on what operations exist.
public enum SyncOperationKind: String, Sendable, CaseIterable, Codable {
    case create
    case update
    case delete
    case attachMedia = "attach_media"
    case submit
    case resolveConflict = "resolve_conflict"
}
