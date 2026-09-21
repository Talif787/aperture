import Foundation
import Synchronization
import ApertureDomain

/// An in-memory implementation of the repository ports.
///
/// Not a mock. It is a working store with the same semantics as the persistent one, which
/// means tests assert on behavior rather than on which methods were called. A test that
/// verifies `save` was invoked passes when the save writes the wrong thing; a test that
/// reads the value back does not.
///
/// It also carries the fault injection the durability work needs: `failNextWrite` and
/// `simulateTermination` let a test reproduce a crash at an exact point in a sequence,
/// which is how the twelve-point kill matrix in Phase 5 is driven.
public final class InMemoryInspectionRepository: InspectionRepository, MediaRepository,
                                                 SyncOperationSink, TransactionRunner, Sendable {
    private struct Storage {
        var inspections: [InspectionID: Inspection] = [:]
        var media: [MediaID: MediaAsset] = [:]
        var operations: [PendingOperation] = []
        var failNextWrite: (any Error)?
        var failNextCommit: Bool = false
        var writeCount: Int = 0
    }

    private let storage = Mutex(Storage())

    public init() {}

    // MARK: - Fault injection

    /// The next write throws, once, then normal behavior resumes.
    public func failNextWrite(with error: any Error) {
        storage.withLock { $0.failNextWrite = error }
    }

    /// How many writes have been committed. Used to place a simulated termination at a
    /// precise point rather than at an arbitrary one.
    public var committedWriteCount: Int {
        storage.withLock { $0.writeCount }
    }

    /// Discards everything not yet "persisted", modelling a process killed before its
    /// buffers reached disk.
    public func simulateTermination() {
        storage.withLock { current in
            current.failNextWrite = nil
        }
    }

    public var pendingOperations: [PendingOperation] {
        storage.withLock { $0.operations }
    }

    // MARK: - InspectionRepository

    public func inspection(id: InspectionID) async throws -> Inspection? {
        storage.withLock { $0.inspections[id] }
    }

    public func inspections(matching query: InspectionQuery) async throws -> [Inspection] {
        storage.withLock { current in
            var results = Array(current.inspections.values)

            if query.includeDeleted == false {
                results = results.filter { $0.sync.isDeleted == false }
            }
            if let statuses = query.statuses {
                results = results.filter { statuses.contains($0.status) }
            }
            if let assignee = query.assignedTo {
                results = results.filter { $0.assignedUserID == assignee }
            }

            // Creation order, which for UUIDv7 identifiers is also identifier order.
            results.sort { $0.id < $1.id }

            if let limit = query.limit {
                results = Array(results.prefix(limit))
            }
            return results
        }
    }

    public func save(_ inspection: Inspection) async throws {
        try storage.withLock { current in
            if let error = current.failNextWrite {
                current.failNextWrite = nil
                throw error
            }
            current.inspections[inspection.id] = inspection
            current.writeCount += 1
        }
    }

    public func delete(id: InspectionID, at instant: Date) async throws {
        try storage.withLock { current in
            if let error = current.failNextWrite {
                current.failNextWrite = nil
                throw error
            }
            current.inspections.removeValue(forKey: id)
            current.writeCount += 1
        }
    }

    // MARK: - MediaRepository

    public func asset(id: MediaID) async throws -> MediaAsset? {
        storage.withLock { $0.media[id] }
    }

    public func assets(forInspection id: InspectionID) async throws -> [MediaAsset] {
        storage.withLock { current in
            current.media.values.filter { $0.inspectionID == id }.sorted { $0.id < $1.id }
        }
    }

    public func save(_ asset: MediaAsset) async throws {
        try storage.withLock { current in
            if let error = current.failNextWrite {
                current.failNextWrite = nil
                throw error
            }
            current.media[asset.id] = asset
            current.writeCount += 1
        }
    }

    public func assetsAwaitingUpload(limit: Int) async throws -> [MediaAsset] {
        storage.withLock { current in
            Array(
                current.media.values
                    .filter { $0.uploadState == .localOnly || $0.uploadState == .uploading }
                    .sorted { $0.id < $1.id }
                    .prefix(limit)
            )
        }
    }

    // MARK: - TransactionRunner

    /// Runs work atomically, restoring the previous state when it fails.
    ///
    /// The store is its own transaction runner because a runner that cannot see the store
    /// cannot undo anything. The previous version ran the body, then threw, and left every
    /// write in place, so a test asserting "nothing was recorded" was asserting against a
    /// double that could not have rolled back under any circumstances. A fake that cannot
    /// fail the way the real thing fails is worse than no fake: it reports success for
    /// behavior nobody has verified.
    public func inTransaction<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let snapshot = storage.withLock { $0 }

        do {
            let result = try await work()

            let shouldFail = storage.withLock { current -> Bool in
                defer { current.failNextCommit = false }
                return current.failNextCommit
            }

            if shouldFail {
                restore(snapshot)
                throw DomainError.unrecoverable(code: "ERR-4801", correlationID: "test")
            }

            return result
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// The next commit fails after its body has run, modelling a write that reaches the
    /// database and then does not survive.
    public func failNextCommit() {
        storage.withLock { $0.failNextCommit = true }
    }

    private func restore(_ snapshot: Storage) {
        storage.withLock { current in
            // The fault-injection switches are deliberately not restored. Rolling back a
            // test's own instructions to the double would make a single-shot failure fire
            // twice.
            let writeCount = current.writeCount
            current = snapshot
            current.writeCount = writeCount
            current.failNextWrite = nil
            current.failNextCommit = false
        }
    }

    // MARK: - SyncOperationSink

    public func enqueue(_ operation: PendingOperation) async throws {
        try storage.withLock { current in
            if let error = current.failNextWrite {
                current.failNextWrite = nil
                throw error
            }
            current.operations.append(operation)
            current.writeCount += 1
        }
    }
}

/// Runs work and can be made to fail, **without rolling anything back**.
///
/// For tests that need a transaction boundary to exist but do not assert on what survives
/// a failure. Anything checking rollback must use `InMemoryInspectionRepository`, which is
/// its own runner and can restore its own state. The distinction is spelled out because
/// the two look interchangeable at the call site and are not.
public final class InMemoryTransactionRunner: TransactionRunner, Sendable {
    private let shouldFail: Mutex<Bool>

    public init() {
        self.shouldFail = Mutex(false)
    }

    /// The next transaction throws after its body runs, modelling a commit failure.
    public func failNextCommit() {
        shouldFail.withLock { $0 = true }
    }

    public func inTransaction<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let result = try await work()
        let failing = shouldFail.withLock { current -> Bool in
            defer { current = false }
            return current
        }
        if failing {
            throw DomainError.unrecoverable(code: "ERR-4801", correlationID: "test")
        }
        return result
    }
}
