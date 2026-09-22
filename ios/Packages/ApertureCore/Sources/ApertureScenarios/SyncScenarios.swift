// swiftlint:disable no_print
//
// This file is a command-line tool, and writing to standard output is its whole purpose.
// The no_print rule exists because print bypasses the redaction that the Telemetry
// protocol applies, which matters in the application where a stray print can put customer
// content in a log. Here there is no log and no customer content: the input is a JSON
// literal the operator typed, and the output goes to their terminal.
//
// Disabled at file scope with a reason rather than removed from the rule, so the rule keeps
// protecting every other file and this exemption is visible to anyone reading it.

import Foundation
import ApertureDomain
import ApertureSync
import ApertureTestSupport

// Synchronization scenarios. Split from main.swift because a single file over four hundred
// lines trips the file_length rule, and because conflict resolution and convergence are a
// different concern from template evaluation.

func printConflictPolicy() {
    let table = ConflictPolicyTable.standard

    print("Per-field conflict policy\n")
    let fields = [
        Finding.Field.measurement, Finding.Field.defectClass, Finding.Field.severity,
        Finding.Field.note, Finding.Field.attachedMedia,
        Inspection.Field.status, Inspection.Field.assignedUser,
        "form.any_template_field"
    ]

    for field in fields {
        print("  \(field.padding(toLength: 24, withPad: " ", startingAt: 0)) \(table.policy(for: field).rawValue)")
    }

    print("")
    print("  Measurements and classifications never resolve automatically, even when the")
    print("  local clock is decisively newer. The number ends up in a document that settles")
    print("  an insurance claim, and silently choosing between two of them is exposure that")
    print("  no convergence guarantee offsets.")
}

func runConflict(local: String, remote: String, localClock: UInt64, remoteClock: UInt64) {
    let localFields = Set(local.split(separator: ",").map(String.init).filter { $0.isEmpty == false })
    let remoteFields = Set(remote.split(separator: ",").map(String.init).filter { $0.isEmpty == false })

    let outcome = ConflictResolver().resolve(
        localDirtyFields: localFields,
        remoteChangedFields: remoteFields,
        localClock: HybridLogicalClock(wallClockMilliseconds: localClock, counter: 0, nodeID: "devA"),
        remoteClock: HybridLogicalClock(wallClockMilliseconds: remoteClock, counter: 0, nodeID: "srv1")
    )

    print("Local changed:  \(localFields.sorted().joined(separator: ", "))")
    print("Remote changed: \(remoteFields.sorted().joined(separator: ", "))")
    print("Local clock \(localClock), remote clock \(remoteClock)\n")

    report("merged automatically (changed on one side only)", outcome.automaticallyMerged)
    report("kept local (newer by hybrid clock)", outcome.resolvedToLocal)
    report("took remote", outcome.resolvedToRemote)
    report("text merged, both contributions kept", outcome.textMerged)
    report("unioned, add-wins", outcome.unioned)
    report("REQUIRES A PERSON, nothing discarded", outcome.requiresHumanDecision)

    print("")
    if outcome.isClean {
        print("  Clean: this syncs without asking anyone.")
    } else {
        print("  Blocked: submission is refused until someone chooses.")
    }
}

func report(_ label: String, _ fields: Set<String>) {
    guard fields.isEmpty == false else { return }
    print("  \(label):")
    for field in fields.sorted() { print("      \(field)") }
}

func runMerge(first: String, second: String) {
    let clockA = HybridLogicalClock(wallClockMilliseconds: 1000, counter: 0, nodeID: "devA")
    let clockB = HybridLogicalClock(wallClockMilliseconds: 2000, counter: 0, nodeID: "srv1")

    let inspector = MergeableNote.single(first, hlc: clockA, authorID: "inspector")
    let reviewer = MergeableNote.single(second, hlc: clockB, authorID: "reviewer")

    let forward = inspector.merged(with: reviewer)
    let backward = reviewer.merged(with: inspector)
    let twice = forward.merged(with: reviewer)

    print("Inspector wrote: \(first)")
    print("Reviewer wrote:  \(second)\n")
    print("Merged:")
    for line in forward.rendered.split(separator: "\n", omittingEmptySubsequences: true) {
        print("    \(line)")
    }

    print("")
    print("  commutative (order of arrival):     \(forward == backward)")
    print("  idempotent (re-delivered edit):     \(twice == forward)")
    print("")
    print("  Neither contribution is discarded. The two authors of a disputed note are an")
    print("  inspector who was on site and a reviewer who was not.")
}

/// Holds the pieces one generated history needs, so the command itself stays readable.
struct ConvergenceWorld {
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
            retryPolicy: RetryPolicy(baseDelay: 0.01, maximumDelay: 0.1, maximumAttempts: 12)
        )
    }
}

func runConverge(seed: UInt64, steps: Int) async {
    let world = ConvergenceWorld(seed: seed)
    var trace: [String] = []

    print("Generated history, seed \(seed), \(steps) steps\n")

    for _ in 0..<steps {
        trace.append(await applyGeneratedStep(in: world))
    }

    print("  \(trace.joined(separator: " "))\n")

    // Time advances between cycles. A backed-off operation waits for a deadline, so a
    // settle loop with a frozen clock reports divergence for an operation that is behaving
    // exactly as designed.
    for _ in 0..<12 {
        world.dateProvider.advance(by: 600)
        _ = try? await world.engine.reconcileAfterLaunch()
        _ = try? await world.engine.synchronize()
    }

    await reportConvergence(world, seed: seed, steps: steps)
}

/// Applies one randomly chosen step and returns its label for the trace.
func applyGeneratedStep(in world: ConvergenceWorld) async -> String {
    let entities = ["finding-1", "finding-2", "finding-3"]
    let fields = [Finding.Field.note, Finding.Field.attachedMedia, Finding.Field.measurement]

    let entity = entities[Int(world.random.value(upperBound: UInt64(entities.count)))]
    let field = fields[Int(world.random.value(upperBound: UInt64(fields.count)))]

    switch world.random.value(upperBound: 100) {
    case 0..<30:
        let operation = SyncOperation(
            id: OperationID(generatedAt: world.dateProvider.now, random: world.random),
            entityType: "finding", entityID: entity, kind: .update,
            dirtyFields: [field],
            baseVersion: world.server.entities[entity]?.version ?? 0,
            hlc: world.clock.send(), createdAt: world.dateProvider.now
        )
        try? await world.queue.enqueue(operation)
        return "local(\(entity).\(field))"

    case 30..<50:
        world.server.applyServerEdit(
            entityID: entity, fields: [field: "server-value"],
            hlc: HybridLogicalClock(
                wallClockMilliseconds: UInt64(world.dateProvider.now.timeIntervalSince1970 * 1000),
                counter: 0, nodeID: "srv1"
            )
        )
        return "remote(\(entity).\(field))"

    case 50..<75:
        _ = try? await world.engine.synchronize()
        return "sync"

    case 75..<83:
        world.server.failNextPush(
            with: DomainError.unrecoverable(code: "ERR-4602", correlationID: "gen")
        )
        _ = try? await world.engine.synchronize()
        return "transportFailure"

    case 83..<90:
        _ = try? await world.engine.reconcileAfterLaunch()
        return "terminate"

    default:
        world.dateProvider.advance(by: Double(world.random.value(upperBound: 120)))
        return "advanceClock"
    }
}

func reportConvergence(_ world: ConvergenceWorld, seed: UInt64, steps: Int) async {
    let outstanding = (try? await world.queue.depth()) ?? -1
    let dead = (try? await world.queue.deadLettered().count) ?? -1
    let stranded = (try? await world.queue.orphanedInFlight().count) ?? -1

    print("After the network settles:")
    print("  outstanding, neither applied nor dead: \(outstanding)")
    print("  dead-lettered, visible to the user:    \(dead)")
    print("  stranded in flight:                    \(stranded)")
    print("  server entities: \(world.server.entities.count), push calls: \(world.server.pushCallCount)")
    print("")

    if outstanding == 0 && stranded == 0 {
        print("  CONVERGED: everything reached the server, resolved as a conflict, or is")
        print("  dead-lettered and visible. Nothing is silently stuck, which is the failure")
        print("  that looks like working software right up until an inspector's day is missing.")
    } else {
        print("  DIVERGED: \(outstanding) outstanding, \(stranded) stranded in flight.")
        print("  Reproduce with: make scenario ARGS=\"converge \(seed) \(steps)\"")
    }
}

