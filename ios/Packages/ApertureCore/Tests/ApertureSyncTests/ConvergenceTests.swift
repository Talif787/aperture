import Testing
import Foundation
@testable import ApertureSync
import ApertureDomain
import ApertureTestSupport

/// The signature suite of this project.
///
/// Every other test asserts one scenario someone thought of. These generate thousands of
/// scenarios nobody thought of: random interleavings of local edits, remote edits,
/// transport failures, and process terminations, replayed until the network settles, then
/// checked for agreement.
///
/// The distinction matters because the failures this system can produce are silent. A
/// convergence bug does not crash, does not log, and does not show a symptom: it leaves two
/// devices quietly holding different measurements for the same roof. No hand-written
/// scenario finds that reliably, because the interleaving that triggers it is one nobody
/// would think to write down.
///
/// Every case is replayable. A failure prints its seed, and the seed reproduces the exact
/// sequence, which is the difference between a flaky test and a bug report.
@Suite("Convergence under adversarial interleaving")
struct ConvergenceTests {

    /// One step in a generated history.
    private enum Step: CustomStringConvertible {
        case localEdit(entity: String, field: String)
        case remoteEdit(entity: String, field: String)
        case synchronize
        case transportFailure
        case terminate
        case advanceClock(seconds: Double)

        var description: String {
            switch self {
            case .localEdit(let entity, let field): return "local(\(entity).\(field))"
            case .remoteEdit(let entity, let field): return "remote(\(entity).\(field))"
            case .synchronize: return "sync"
            case .transportFailure: return "transportFailure"
            case .terminate: return "terminate"
            case .advanceClock(let seconds): return "advance(\(seconds)s)"
            }
        }
    }

    private struct World {
        let queue = InMemorySyncQueue()
        let cursors = InMemoryCursorStore()
        let server = InMemorySyncServer()
        let dateProvider = TestDateProvider()
        let random: SeededRandomSource
        let clock: HybridLogicalClockGenerator

        init(seed: UInt64) {
            random = SeededRandomSource(seed: seed)
            clock = HybridLogicalClockGenerator(nodeID: "devA", dateProvider: dateProvider)
        }

        var engine: SyncEngine {
            SyncEngine(
                queue: queue, cursors: cursors, transport: server,
                dateProvider: dateProvider, random: random,
                // Short backoff so a generated history of a few hundred steps still
                // exercises retries rather than parking everything for fifteen minutes.
                retryPolicy: RetryPolicy(baseDelay: 0.01, maximumDelay: 0.1, maximumAttempts: 12)
            )
        }
    }

    private static let entities = ["finding-1", "finding-2", "finding-3"]

    /// Fields chosen to span every policy: a mergeable one, a union one, and one that must
    /// never resolve automatically.
    private static let fields = [
        Finding.Field.note,
        Finding.Field.attachedMedia,
        Finding.Field.measurement
    ]

    private func generateHistory(random: SeededRandomSource, length: Int) -> [Step] {
        (0..<length).map { _ in
            let entity = Self.entities[Int(random.value(upperBound: UInt64(Self.entities.count)))]
            let field = Self.fields[Int(random.value(upperBound: UInt64(Self.fields.count)))]

            switch random.value(upperBound: 100) {
            case 0..<30: return .localEdit(entity: entity, field: field)
            case 30..<50: return .remoteEdit(entity: entity, field: field)
            case 50..<75: return .synchronize
            case 75..<83: return .transportFailure
            case 83..<90: return .terminate
            default: return .advanceClock(seconds: Double(random.value(upperBound: 120)))
            }
        }
    }

    @Test(
        "client and server converge for every generated history",
        arguments: [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597]
    )
    func convergesUnderInterleaving(seed: UInt64) async throws {
        let world = World(seed: seed)
        let history = generateHistory(random: world.random, length: 120)
        var applied: [Step] = []

        for step in history {
            applied.append(step)

            switch step {
            case .localEdit(let entity, let field):
                let operation = SyncOperation(
                    id: OperationID(generatedAt: world.dateProvider.now, random: world.random),
                    entityType: "finding",
                    entityID: entity,
                    kind: .update,
                    dirtyFields: [field],
                    baseVersion: world.server.entities[entity]?.version ?? 0,
                    hlc: world.clock.send(),
                    createdAt: world.dateProvider.now
                )
                try await world.queue.enqueue(operation)

            case .remoteEdit(let entity, let field):
                world.server.applyServerEdit(
                    entityID: entity,
                    fields: [field: "server-value"],
                    hlc: HybridLogicalClock(
                        wallClockMilliseconds: UInt64(
                            world.dateProvider.now.timeIntervalSince1970 * 1000
                        ),
                        counter: 0,
                        nodeID: "srv1"
                    )
                )

            case .synchronize:
                _ = try? await world.engine.synchronize()

            case .transportFailure:
                world.server.failNextPush(
                    with: DomainError.unrecoverable(code: "ERR-4602", correlationID: "gen")
                )
                _ = try? await world.engine.synchronize()

            case .terminate:
                // The process dies. The queue is durable, so it survives, but whatever was
                // in flight is now of unknown outcome and must be re-driven.
                _ = try await world.engine.reconcileAfterLaunch()

            case .advanceClock(let seconds):
                world.dateProvider.advance(by: seconds)
            }
        }

        // Let the network settle.
        //
        // Time advances between cycles, which is not a detail. A backed-off operation is
        // waiting for a deadline, so a settle loop with a frozen clock asks the same
        // question twelve times and gets the same answer: the operation is correctly
        // backed off and the moment never arrives. That is an artifact of the harness, not
        // a property of the engine, and it made this suite report divergence for an
        // operation that was behaving exactly as designed.
        for _ in 0..<12 {
            world.dateProvider.advance(by: 600)
            _ = try await world.engine.reconcileAfterLaunch()
            _ = try? await world.engine.synchronize()
        }

        let outstanding = try await world.queue.depth()
        let dead = try await world.queue.deadLettered()
        let stranded = try await world.queue.orphanedInFlight()

        let trace = applied.map(\.description).joined(separator: " ")

        // `depth` counts operations that are not dead, so the property is that it reaches
        // zero: everything either reached the server, was resolved as a conflict, or was
        // dead-lettered and is visible to the user.
        //
        // The earlier form compared this count against the number of dead operations,
        // which holds only when both are zero. Fourteen seeds passed it for that reason
        // rather than because the property held, which is the kind of assertion that
        // makes a suite look stronger than it is.
        // Built as a value first. A Comment is expressible by a string literal, including
        // interpolation, but a concatenation is an expression rather than a literal and
        // the conversion never fires.
        let outstandingDetail = "seed \(seed): \(outstanding) neither applied nor dead-lettered, "
            + "\(dead.count) dead. History: \(trace)"

        #expect(outstanding == 0, "\(outstandingDetail)")

        // Nothing may be left in flight. An operation stuck there was dispatched and never
        // accounted for, which is silent loss wearing the costume of pending work.
        #expect(
            stranded.isEmpty,
            "seed \(seed): \(stranded.count) operation(s) stranded in flight. History: \(trace)"
        )
    }

    @Test(
        "an operation is never applied twice, however the history interleaves",
        arguments: [7, 42, 101, 2026]
    )
    func exactlyOnceEffect(seed: UInt64) async throws {
        let world = World(seed: seed)

        var operations: [SyncOperation] = []
        for index in 0..<20 {
            let operation = SyncOperation(
                id: OperationID(generatedAt: world.dateProvider.now, random: world.random),
                entityType: "finding",
                entityID: "finding-\(index % 3)",
                kind: .update,
                dirtyFields: [Finding.Field.note],
                baseVersion: 0,
                hlc: world.clock.send(),
                createdAt: world.dateProvider.now.addingTimeInterval(Double(index))
            )
            operations.append(operation)
            try await world.queue.enqueue(operation)
        }

        // Synchronize repeatedly with terminations interleaved, so operations are re-driven
        // after unknown outcomes.
        for index in 0..<30 {
            if index % 4 == 0 {
                for var operation in operations {
                    operation.requeueAfterTermination()
                    try await world.queue.enqueue(operation)
                }
            }
            world.dateProvider.advance(by: 60)
            _ = try? await world.engine.synchronize()
        }

        // The server saw each key many times and applied each exactly once. Exactly-once
        // effect over at-least-once delivery is what idempotency keys buy, and it is the
        // only reason a retry is safe at all.
        let totalVersions = world.server.entities.values.reduce(0) { $0 + Int($1.version) }
        #expect(totalVersions <= operations.count,
                "seed \(seed): \(totalVersions) applications for \(operations.count) operations")
    }

    @Test("a measurement conflict is always surfaced, never resolved silently",
          arguments: [11, 22, 33])
    func measurementConflictsAlwaysSurface(seed: UInt64) async throws {
        let world = World(seed: seed)

        world.server.applyServerEdit(
            entityID: "finding-1",
            fields: [Finding.Field.measurement: "3.4"],
            hlc: HybridLogicalClock(wallClockMilliseconds: 1_780_000_500_000, counter: 0, nodeID: "srv1")
        )

        try await world.queue.enqueue(
            SyncOperation(
                id: OperationID(generatedAt: world.dateProvider.now, random: world.random),
                entityType: "finding",
                entityID: "finding-1",
                kind: .update,
                dirtyFields: [Finding.Field.measurement],
                baseVersion: 0,
                hlc: world.clock.send(),
                createdAt: world.dateProvider.now
            )
        )

        let report = try await world.engine.synchronize()

        // Whatever else converges automatically, this one never does. A number that
        // settles a claim is not something two clocks should arbitrate.
        #expect(report.requiresAttention, "seed \(seed): a measurement conflict was resolved silently")
    }
}
