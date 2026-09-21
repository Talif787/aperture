import Foundation
import Synchronization
import ApertureDomain
import ApertureSync

/// An in-memory queue with the real ordering semantics.
///
/// Per-entity ordering is implemented here rather than stubbed, because it is the property
/// the engine depends on and a double that returns everything would let a broken engine
/// pass.
public final class InMemorySyncQueue: SyncQueue, Sendable {
    private let storage = Mutex([OperationID: SyncOperation]())

    public init() {}

    public var all: [SyncOperation] {
        storage.withLock { Array($0.values).sorted { $0.createdAt < $1.createdAt } }
    }

    public func enqueue(_ operation: SyncOperation) async throws {
        storage.withLock { $0[operation.id] = operation }
    }

    public func dispatchable(limit: Int, at instant: Date) async throws -> [SyncOperation] {
        storage.withLock { current in
            let ready = current.values
                .filter { $0.isDispatchable(at: instant) }
                .sorted { ($0.createdAt, $0.id.description) < ($1.createdAt, $1.id.description) }

            // At most one per entity. Sending two edits to the same record concurrently
            // would make the second one's baseVersion stale before the server saw it, and
            // the client would generate a conflict against itself.
            var seenEntities: Set<String> = []
            var selected: [SyncOperation] = []

            for operation in ready where selected.count < limit {
                guard seenEntities.contains(operation.entityID) == false else { continue }
                seenEntities.insert(operation.entityID)
                selected.append(operation)
            }

            return selected
        }
    }

    public func operation(id: OperationID) async throws -> SyncOperation? {
        storage.withLock { $0[id] }
    }

    public func operations(forEntity entityID: String) async throws -> [SyncOperation] {
        storage.withLock { current in
            current.values
                .filter { $0.entityID == entityID }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func update(_ operation: SyncOperation) async throws {
        storage.withLock { $0[operation.id] = operation }
    }

    public func remove(id: OperationID) async throws {
        // The discard is explicit. `removeValue` returns what it removed, which becomes
        // the closure's result and then goes unused, and a warning for a deliberate
        // discard is noise that trains people to ignore warnings.
        storage.withLock { current in
            _ = current.removeValue(forKey: id)
        }
    }

    public func orphanedInFlight() async throws -> [SyncOperation] {
        storage.withLock { $0.values.filter { $0.state == .inFlight } }
    }

    public func deadLettered() async throws -> [SyncOperation] {
        storage.withLock { $0.values.filter { $0.state == .dead } }
    }

    public func depth() async throws -> Int {
        storage.withLock { $0.values.filter { $0.state != .dead }.count }
    }

    /// Discards everything not yet durably written, modelling a process killed before its
    /// buffers reached disk.
    public func simulateTermination() {
        // The queue is the durable record, so termination does not lose it. What it does
        // lose is the knowledge of which requests were actually sent, which is exactly why
        // inFlight operations are re-driven rather than assumed applied.
    }
}

public final class InMemoryCursorStore: SyncCursorStore, Sendable {
    private let storage = Mutex<String?>(nil)

    public init(initial: String? = nil) {
        storage.withLock { $0 = initial }
    }

    public var current: String? { storage.withLock { $0 } }

    public func cursor() async throws -> String? { storage.withLock { $0 } }
    public func setCursor(_ cursor: String) async throws { storage.withLock { $0 = cursor } }
    public func clearCursor() async throws { storage.withLock { $0 = nil } }
}

/// A server that keeps versioned entities and enforces optimistic concurrency.
///
/// Not a stub returning canned answers. It applies the same version-comparison rule the
/// real service does, which is what lets a convergence test mean anything: if the double
/// accepted everything, "the replicas agree" would be a statement about the double.
public final class InMemorySyncServer: SyncTransport, Sendable {
    public struct Entity: Sendable, Equatable {
        public var version: Int64
        public var fields: [String: String]
        public var hlc: HybridLogicalClock
    }

    private struct Storage {
        var entities: [String: Entity] = [:]
        var changeLog: [RemoteChange] = []
        var idempotencyKeys: [String: PushResult] = [:]
        var failNextPush: (any Error)?
        var pushCallCount = 0
    }

    private let storage = Mutex(Storage())
    private let nodeID: String

    public init(nodeID: String = "srv1") {
        self.nodeID = nodeID
    }

    public var entities: [String: Entity] { storage.withLock { $0.entities } }
    public var pushCallCount: Int { storage.withLock { $0.pushCallCount } }

    public func failNextPush(with error: any Error) {
        storage.withLock { $0.failNextPush = error }
    }

    /// Applies a change originating on the server, as a reviewer would.
    public func applyServerEdit(
        entityID: String,
        fields: [String: String],
        hlc: HybridLogicalClock
    ) {
        storage.withLock { current in
            var entity = current.entities[entityID]
                ?? Entity(version: 0, fields: [:], hlc: hlc)
            entity.version += 1
            entity.hlc = hlc
            for (key, value) in fields { entity.fields[key] = value }
            current.entities[entityID] = entity

            current.changeLog.append(
                RemoteChange(
                    entityType: "finding",
                    entityID: entityID,
                    serverVersion: entity.version,
                    hlc: hlc,
                    changedFields: Set(fields.keys)
                )
            )
        }
    }

    public func pullChanges(since cursor: String?, limit: Int) async throws -> ChangePage {
        storage.withLock { current in
            let start = cursor.flatMap(Int.init) ?? 0
            let slice = Array(current.changeLog.dropFirst(start).prefix(limit))
            let next = start + slice.count
            return ChangePage(
                changes: slice,
                nextCursor: String(next),
                hasMore: next < current.changeLog.count
            )
        }
    }

    public func pushDeltas(_ operations: [SyncOperation]) async throws -> [PushResult] {
        let failure = storage.withLock { current -> (any Error)? in
            current.pushCallCount += 1
            defer { current.failNextPush = nil }
            return current.failNextPush
        }
        if let failure { throw failure }

        return storage.withLock { current in
            operations.map { operation in
                // Replay before anything else. A retry after an unknown outcome must
                // return the original answer, not a second application.
                if let stored = current.idempotencyKeys[operation.idempotencyKey] {
                    switch stored {
                    case .applied(_, let version):
                        return .replayed(operationID: operation.id, serverVersion: version)
                    default:
                        return stored
                    }
                }

                var entity = current.entities[operation.entityID]
                    ?? Entity(version: 0, fields: [:], hlc: operation.hlc)

                let result: PushResult
                if entity.version != operation.baseVersion {
                    // A version mismatch alone is not a conflict. Only an overlapping
                    // field is, which is the same rule the client applies.
                    let overlapping = operation.dirtyFields.intersection(Set(entity.fields.keys))
                    if overlapping.isEmpty {
                        entity.version += 1
                        entity.hlc = operation.hlc
                        for field in operation.dirtyFields { entity.fields[field] = operation.id.description }
                        current.entities[operation.entityID] = entity
                        result = .applied(operationID: operation.id, serverVersion: entity.version)
                    } else {
                        result = .conflict(
                            operationID: operation.id,
                            serverVersion: entity.version,
                            conflictingFields: overlapping
                        )
                    }
                } else {
                    entity.version += 1
                    entity.hlc = operation.hlc
                    for field in operation.dirtyFields { entity.fields[field] = operation.id.description }
                    current.entities[operation.entityID] = entity
                    result = .applied(operationID: operation.id, serverVersion: entity.version)
                }

                current.idempotencyKeys[operation.idempotencyKey] = result
                return result
            }
        }
    }
}

/// A transport that fails a scripted number of times before succeeding.
public final class FlakySyncTransport: SyncTransport, Sendable {
    private let inner: any SyncTransport
    private let remainingFailures: Mutex<Int>
    private let error: any Error

    public init(wrapping inner: any SyncTransport, failures: Int, error: any Error) {
        self.inner = inner
        self.remainingFailures = Mutex(failures)
        self.error = error
    }

    private func consumeFailure() throws {
        let shouldFail = remainingFailures.withLock { current -> Bool in
            guard current > 0 else { return false }
            current -= 1
            return true
        }
        if shouldFail { throw error }
    }

    public func pullChanges(since cursor: String?, limit: Int) async throws -> ChangePage {
        try consumeFailure()
        return try await inner.pullChanges(since: cursor, limit: limit)
    }

    public func pushDeltas(_ operations: [SyncOperation]) async throws -> [PushResult] {
        try consumeFailure()
        return try await inner.pushDeltas(operations)
    }
}
