import Testing
import Foundation
@testable import ApertureSync
import ApertureDomain
import ApertureTestSupport

/// Shared setup, lifted to file scope so each suite stays focused on one concern.
private struct Harness {
    let queue = InMemorySyncQueue()
    let cursors = InMemoryCursorStore()
    let server = InMemorySyncServer()
    let dateProvider = TestDateProvider()
    let random = SeededRandomSource(seed: 17)

    func engine(transport: (any SyncTransport)? = nil) -> SyncEngine {
        SyncEngine(
            queue: queue,
            cursors: cursors,
            transport: transport ?? server,
            dateProvider: dateProvider,
            random: random
        )
    }

    func operation(
        entity: String,
        fields: Set<String>,
        baseVersion: Int64 = 0,
        offsetMilliseconds: UInt64 = 0
    ) -> SyncOperation {
        SyncOperation(
            id: OperationID(generatedAt: dateProvider.now, random: random),
            entityType: "finding",
            entityID: entity,
            kind: .update,
            dirtyFields: fields,
            baseVersion: baseVersion,
            hlc: HybridLogicalClock(
                wallClockMilliseconds: 1_780_000_000_000 + offsetMilliseconds,
                counter: 0,
                nodeID: "devA"
            ),
            createdAt: dateProvider.now.addingTimeInterval(Double(offsetMilliseconds) / 1000)
        )
    }

    func serverEdit(entity: String, field: String, atMilliseconds milliseconds: UInt64) {
        server.applyServerEdit(
            entityID: entity,
            fields: [field: "server-value"],
            hlc: HybridLogicalClock(wallClockMilliseconds: milliseconds, counter: 0, nodeID: "srv1")
        )
    }
}

@Suite("Sync cycle")
struct SyncCycleTests {

    @Test("an empty queue and an empty server is a no-op")
    func emptyCycle() async throws {
        let harness = Harness()

        let report = try await harness.engine().synchronize()

        #expect(report.pulled == 0)
        #expect(report.applied == 0)
        #expect(report.requiresAttention == false)
    }

    @Test("a queued operation is pushed and then removed")
    func pushRemovesOnSuccess() async throws {
        let harness = Harness()
        try await harness.queue.enqueue(harness.operation(entity: "finding-1", fields: ["note"]))

        let report = try await harness.engine().synchronize()

        #expect(report.applied == 1)
        #expect(try await harness.queue.depth() == 0)
    }

    @Test("pull happens before push")
    func pullPrecedesPush() async throws {
        let harness = Harness()
        harness.serverEdit(entity: "finding-1", field: "severity", atMilliseconds: 1_780_000_100_000)
        try await harness.queue.enqueue(harness.operation(entity: "finding-1", fields: ["note"]))

        let report = try await harness.engine().synchronize()

        // Sending local work against server state the device has not seen produces
        // conflicts the client could have resolved locally, and reports them to the user
        // as decisions when the information to decide with was one request away.
        #expect(report.pulled == 1)
        #expect(report.autoMerged == 1, "different fields should merge without a prompt")
    }

    @Test("the cursor advances only after its page is applied")
    func cursorAdvancesAfterApply() async throws {
        let harness = Harness()
        harness.serverEdit(entity: "finding-1", field: "severity", atMilliseconds: 1)

        #expect(harness.cursors.current == nil)
        _ = try await harness.engine().synchronize()

        // Advancing first would mean a crash mid-page silently skips changes, and nothing
        // downstream could detect the gap.
        #expect(harness.cursors.current == "1")
    }

    @Test("an overlapping field produces a conflict the user must resolve")
    func overlappingFieldConflicts() async throws {
        let harness = Harness()
        harness.serverEdit(
            entity: "finding-1",
            field: Finding.Field.measurement,
            atMilliseconds: 1_780_000_100_000
        )
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-1", fields: [Finding.Field.measurement])
        )

        let report = try await harness.engine().synchronize()

        #expect(report.requiresAttention)
        #expect(report.conflictedEntities.contains("finding-1"))
    }

    @Test("a retry presents the same idempotency key and the server replays")
    func retryIsIdempotent() async throws {
        let harness = Harness()
        let operation = harness.operation(entity: "finding-1", fields: ["note"])
        try await harness.queue.enqueue(operation)

        _ = try await harness.engine().synchronize()

        var replayed = operation
        replayed.requeueAfterTermination()
        try await harness.queue.enqueue(replayed)
        let second = try await harness.engine().synchronize()

        // Exactly one server-side effect over an at-least-once channel.
        #expect(second.replayed == 1)
        #expect(harness.server.entities["finding-1"]?.version == 1)
    }

    @Test("a transport failure returns every operation to the queue")
    func transportFailurePreservesWork() async throws {
        let harness = Harness()
        try await harness.queue.enqueue(harness.operation(entity: "finding-1", fields: ["note"]))
        harness.server.failNextPush(
            with: DomainError.unrecoverable(code: "ERR-4602", correlationID: "t")
        )

        await #expect(throws: (any Error).self) {
            _ = try await harness.engine().synchronize()
        }

        // The outcome is unknown, not failed. The work stays queued with its key intact.
        #expect(try await harness.queue.depth() == 1)
    }
}

@Suite("Queue behavior")
struct SyncQueueBehaviorTests {

    @Test("operations abandoned in flight are re-driven on the next launch")
    func reconciliationRequeuesOrphans() async throws {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        operation.markInFlight()
        try await harness.queue.enqueue(operation)

        let requeued = try await harness.engine().reconcileAfterLaunch()

        #expect(requeued == 1)
        let ready = try await harness.queue.dispatchable(limit: 10, at: harness.dateProvider.now)
        #expect(ready.count == 1)
    }

    @Test("a re-drive after termination does not burn a retry")
    func terminationDoesNotCountAsAFailure() {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        operation.markInFlight()
        let attemptsBefore = operation.attemptCount

        operation.requeueAfterTermination()

        // The process died; the server may never have seen the request. Counting it as a
        // failure would spend a retry the operation never had.
        #expect(operation.attemptCount == attemptsBefore)
        #expect(operation.state == .pending)
    }

    @Test("only one operation per entity is dispatched at a time")
    func perEntityOrdering() async throws {
        let harness = Harness()
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-1", fields: ["note"], offsetMilliseconds: 0)
        )
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-1", fields: ["severity"], offsetMilliseconds: 10)
        )
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-2", fields: ["note"], offsetMilliseconds: 20)
        )

        let batch = try await harness.queue.dispatchable(limit: 10, at: harness.dateProvider.now)

        // Two edits to the same record sent together would make the second one's
        // baseVersion stale before the server saw it, and the client would generate a
        // conflict against itself.
        #expect(batch.count == 2)
        #expect(Set(batch.map(\.entityID)) == ["finding-1", "finding-2"])
    }

    @Test("a poisoned operation on one entity does not block another")
    func noHeadOfLineBlocking() async throws {
        let harness = Harness()
        var poisoned = harness.operation(entity: "finding-1", fields: ["note"])
        poisoned.markInFlight()
        poisoned.markFailed(
            code: "ERR-4001", policy: .standard,
            now: harness.dateProvider.now, random: harness.random
        )
        try await harness.queue.enqueue(poisoned)
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-2", fields: ["note"], offsetMilliseconds: 10)
        )

        let report = try await harness.engine().synchronize()

        // Strict global ordering would mean one stuck operation reads to a field user as
        // "sync stopped working", with nothing to indicate which record is at fault.
        #expect(report.applied == 1)
    }

    @Test("an exhausted operation is dead-lettered rather than retried forever")
    func deadLettering() {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        let policy = RetryPolicy(baseDelay: 1, maximumDelay: 2, maximumAttempts: 2)

        for _ in 0..<3 {
            operation.markInFlight()
            operation.markFailed(
                code: "ERR-4604", policy: policy,
                now: harness.dateProvider.now, random: harness.random
            )
        }

        // An infinite retry loop on a field device is a silent battery drain with no
        // possible success. Dead-lettered work surfaces to the user with a reason instead.
        #expect(operation.state == .dead)
        #expect(operation.state.requiresUserAttention)
    }

    @Test("a failed operation is dispatched again once its backoff elapses")
    func failedOperationsRetry() async throws {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        operation.markInFlight()
        operation.markFailed(
            code: "ERR-4604", policy: .standard,
            now: harness.dateProvider.now, random: harness.random
        )
        try await harness.queue.enqueue(operation)

        // Without this, `failed` was a terminal state in everything but name: never
        // dispatched, never dead-lettered, and counted forever as queued work that could
        // not move. The convergence suite is what noticed.
        #expect(operation.state == .failed)
        let later = try await harness.queue.dispatchable(
            limit: 10, at: harness.dateProvider.now.addingTimeInterval(3600)
        )
        #expect(later.count == 1)
    }

    @Test("an in-flight operation can still be looked up by identifier")
    func inFlightOperationsAreAddressable() async throws {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        operation.markInFlight()
        try await harness.queue.enqueue(operation)

        // Handling a push result means finding an operation that is in flight by
        // definition. Looking it up through the dispatch query could never work, and the
        // result handler silently returned every time.
        #expect(try await harness.queue.operation(id: operation.id) != nil)
        #expect(try await harness.queue.dispatchable(limit: 10, at: harness.dateProvider.now).isEmpty)
    }

    @Test("every local edit for an entity is visible to conflict detection")
    func allEditsForAnEntityAreVisible() async throws {
        let harness = Harness()
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-1", fields: ["note"], offsetMilliseconds: 0)
        )
        try await harness.queue.enqueue(
            harness.operation(entity: "finding-1", fields: ["severity"], offsetMilliseconds: 10)
        )

        let all = try await harness.queue.operations(forEntity: "finding-1")
        let dispatchable = try await harness.queue.dispatchable(
            limit: 10, at: harness.dateProvider.now
        )

        // Dispatch returns one per entity; conflict detection needs the union. Using the
        // dispatch query for both would compare a remote change against a fraction of the
        // local edits and miss overlaps.
        #expect(all.count == 2)
        #expect(dispatchable.count == 1)
    }

    @Test("a backed-off operation is not dispatched before its time")
    func backoffIsRespected() async throws {
        let harness = Harness()
        var operation = harness.operation(entity: "finding-1", fields: ["note"])
        operation.markInFlight()
        operation.markFailed(
            code: "ERR-4604", policy: .standard,
            now: harness.dateProvider.now, random: harness.random
        )
        operation.returnToPending()
        try await harness.queue.update(operation)

        let tooEarly = try await harness.queue.dispatchable(
            limit: 10, at: harness.dateProvider.now
        )
        let later = try await harness.queue.dispatchable(
            limit: 10, at: harness.dateProvider.now.addingTimeInterval(3600)
        )

        #expect(tooEarly.isEmpty)
        #expect(later.count == 1)
    }
}
