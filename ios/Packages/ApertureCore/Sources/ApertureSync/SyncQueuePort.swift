import Foundation
import ApertureDomain

/// The durable operation queue.
///
/// Ordered **per entity**, not globally. Strict global ordering would mean one poisoned
/// operation on inspection A blocks every other inspection, which a field user experiences
/// as "sync stopped working" with no indication why. Per-entity ordering keeps causality
/// where it matters and isolates failures where it does not.
public protocol SyncQueue: Sendable {
    func enqueue(_ operation: SyncOperation) async throws

    /// Operations ready to send, at most one per entity, oldest first.
    func dispatchable(limit: Int, at instant: Date) async throws -> [SyncOperation]

    /// One operation by identifier, in any state.
    ///
    /// Distinct from `dispatchable` on purpose. Looking an operation up through the
    /// dispatch query cannot work for the case that needs it most: handling a push result
    /// means finding an operation that is currently in flight, and in-flight operations
    /// are by definition not dispatchable. The lookup missed every time, the result
    /// handler returned early, and the operation stayed in flight forever.
    func operation(id: OperationID) async throws -> SyncOperation?

    /// Every queued operation for one entity, in any state.
    ///
    /// Conflict detection needs the union of what the device has changed for a record. The
    /// dispatch query returns at most one operation per entity, so using it here would
    /// compare a remote change against a fraction of the local edits and miss overlaps.
    func operations(forEntity entityID: String) async throws -> [SyncOperation]

    func update(_ operation: SyncOperation) async throws
    func remove(id: OperationID) async throws

    /// Operations a terminated process left mid-request.
    func orphanedInFlight() async throws -> [SyncOperation]

    /// Operations that exhausted their retries and need a person.
    func deadLettered() async throws -> [SyncOperation]

    func depth() async throws -> Int
}

/// Where the device's position in the server change stream is kept.
///
/// Per device, not per user. One inspector with an iPhone and an iPad is ordinary in this
/// product, and a shared cursor would let one device's progress hide changes from the other.
public protocol SyncCursorStore: Sendable {
    func cursor() async throws -> String?
    func setCursor(_ cursor: String) async throws
    func clearCursor() async throws
}

/// The wire operations the engine needs.
public protocol SyncTransport: Sendable {
    func pullChanges(since cursor: String?, limit: Int) async throws -> ChangePage
    func pushDeltas(_ operations: [SyncOperation]) async throws -> [PushResult]
}

public struct ChangePage: Sendable, Equatable {
    public let changes: [RemoteChange]
    public let nextCursor: String

    /// True when the server has more to send and the engine should page again.
    public let hasMore: Bool

    public init(changes: [RemoteChange], nextCursor: String, hasMore: Bool) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteChange: Sendable, Equatable {
    public let entityType: String
    public let entityID: String
    public let serverVersion: Int64
    public let hlc: HybridLogicalClock
    public let changedFields: Set<String>
    public let isDeletion: Bool

    public init(
        entityType: String,
        entityID: String,
        serverVersion: Int64,
        hlc: HybridLogicalClock,
        changedFields: Set<String>,
        isDeletion: Bool = false
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.serverVersion = serverVersion
        self.hlc = hlc
        self.changedFields = changedFields
        self.isDeletion = isDeletion
    }
}

/// What the server made of one pushed operation.
///
/// `replayed` is distinct from `applied` on purpose. Collapsing them would hide client
/// retry storms, which is exactly the signal an operator needs when a fleet reconnects at
/// shift end and something is going wrong.
public enum PushResult: Sendable, Equatable {
    case applied(operationID: OperationID, serverVersion: Int64)
    case replayed(operationID: OperationID, serverVersion: Int64)
    case conflict(operationID: OperationID, serverVersion: Int64, conflictingFields: Set<String>)
    case rejected(operationID: OperationID, code: String, retryable: Bool)

    public var operationID: OperationID {
        switch self {
        case .applied(let id, _), .replayed(let id, _):
            return id
        case .conflict(let id, _, _):
            return id
        case .rejected(let id, _, _):
            return id
        }
    }
}
