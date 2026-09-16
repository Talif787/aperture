import Foundation

/// The ports the domain defines and the data layer implements.
///
/// These are declared here, alongside the entities they serve, rather than next to their
/// implementations. That is what lets the domain be compiled and tested with no database,
/// no network, and no simulator, which in turn is what keeps the hardest logic in the
/// product covered by the fastest tests.

/// Read and write access to inspections.
public protocol InspectionRepository: Sendable {
    func inspection(id: InspectionID) async throws -> Inspection?
    func inspections(matching query: InspectionQuery) async throws -> [Inspection]
    func save(_ inspection: Inspection) async throws
    func delete(id: InspectionID, at instant: Date) async throws
}

/// A query over locally held inspections.
///
/// Expressed as a value rather than as a predicate closure so it can cross an actor
/// boundary, be logged, and be translated into either a SwiftData predicate or plain SQL
/// without the domain knowing which.
public struct InspectionQuery: Sendable, Equatable {
    public var statuses: Set<Inspection.Status>?
    public var assignedTo: UserID?
    public var includeDeleted: Bool
    public var limit: Int?

    public init(
        statuses: Set<Inspection.Status>? = nil,
        assignedTo: UserID? = nil,
        includeDeleted: Bool = false,
        limit: Int? = nil
    ) {
        self.statuses = statuses
        self.assignedTo = assignedTo
        self.includeDeleted = includeDeleted
        self.limit = limit
    }

    /// Everything the inspector can still work on.
    public static let openWork = InspectionQuery(statuses: [.draft, .changesRequested])
}

/// Metadata access for captured media. Bytes are handled separately, by the media store,
/// because they never belong in a database row.
public protocol MediaRepository: Sendable {
    func asset(id: MediaID) async throws -> MediaAsset?
    func assets(forInspection id: InspectionID) async throws -> [MediaAsset]
    func save(_ asset: MediaAsset) async throws
    func assetsAwaitingUpload(limit: Int) async throws -> [MediaAsset]
}

/// A unit of work.
///
/// The entity write, its version increment, and the sync operation it produces must commit
/// together or not at all. Without that atomicity a crash between the two leaves an edit
/// the user can see and the server will never hear about, which is precisely the class of
/// silent loss this product cannot have.
public protocol TransactionRunner: Sendable {
    func inTransaction<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T
}

/// Where sync operations are durably queued. The queue itself is built in Phase 5; the
/// port is declared now so the repositories written against it do not change later.
public protocol SyncOperationSink: Sendable {
    func enqueue(_ operation: PendingOperation) async throws
}

/// A durable record of an intent to change server state.
public struct PendingOperation: Sendable, Equatable {
    public let id: OperationID
    public let entityType: String
    public let entityID: String
    public let kind: String
    public let dirtyFields: Set<String>
    public let baseVersion: Int64
    public let hlc: HybridLogicalClock
    public let createdAt: Date

    /// The identifier doubles as the idempotency key.
    ///
    /// Generated on the device at the moment the intent is recorded, so a retry after an
    /// unknown outcome carries the same key and the server replays its stored response
    /// rather than applying the effect twice.
    public var idempotencyKey: String { id.description }

    public init(
        id: OperationID,
        entityType: String,
        entityID: String,
        kind: String,
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
    }
}
