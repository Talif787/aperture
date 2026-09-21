import Foundation
import ApertureDomain

/// Orchestrates one synchronization cycle.
///
/// An actor, so concurrent triggers collapse into one run. There are five of them in this
/// product (foreground, connectivity change, silent push, background task, manual pull) and
/// several routinely fire at once when a vehicle comes back into coverage. Two cycles
/// racing would double-send operations and interleave cursor writes.
public actor SyncEngine {
    private let queue: any SyncQueue
    private let cursors: any SyncCursorStore
    private let transport: any SyncTransport
    private let resolver: ConflictResolver
    private let retryPolicy: RetryPolicy
    private let dateProvider: any DateProviding
    private let random: any RandomSource
    private let telemetry: any Telemetry

    /// How many changes to pull per request, and how many operations to push per batch.
    ///
    /// Bounded so a marginal cellular link can finish a request before it times out. A
    /// device that has been dark for three days has hundreds of operations, and sending
    /// them as one payload means a single timeout discards all of that progress.
    private let pageSize: Int
    private let batchSize: Int

    /// Guards against pulling forever when a server keeps reporting more.
    private let maximumPullPages: Int

    /// Required dependencies first, defaulted ones after.
    ///
    /// Swift requires arguments in declaration order, so interleaving defaulted parameters
    /// among required ones makes the obvious call site a compile error for a reason that
    /// has nothing to do with the caller. Ordering them this way removes the trap instead
    /// of leaving each caller to discover it.
    public init(
        queue: any SyncQueue,
        cursors: any SyncCursorStore,
        transport: any SyncTransport,
        dateProvider: any DateProviding,
        random: any RandomSource,
        resolver: ConflictResolver = ConflictResolver(),
        retryPolicy: RetryPolicy = .standard,
        telemetry: any Telemetry = NoOpTelemetry(),
        pageSize: Int = 200,
        batchSize: Int = 100,
        maximumPullPages: Int = 50
    ) {
        self.queue = queue
        self.cursors = cursors
        self.transport = transport
        self.resolver = resolver
        self.retryPolicy = retryPolicy
        self.dateProvider = dateProvider
        self.random = random
        self.telemetry = telemetry
        self.pageSize = pageSize
        self.batchSize = batchSize
        self.maximumPullPages = maximumPullPages
    }

    /// Runs one cycle: pull, apply, then push.
    ///
    /// Pull precedes push, always. Sending local work against server state the device has
    /// not seen produces conflicts the client could have resolved locally, and worse, it
    /// reports them to the user as decisions to make when the information to decide with
    /// was one request away.
    public func synchronize() async throws -> SyncReport {
        var report = SyncReport()

        report.pulled = try await pull(into: &report)
        try await push(into: &report)

        report.queueDepth = try await queue.depth()
        report.deadLettered = try await queue.deadLettered().count

        telemetry.event("sync.cycle_completed", attributes: [
            "pulled": .count(report.pulled),
            "pushed": .count(report.applied),
            "conflicts": .count(report.conflicted),
            "depth": .count(report.queueDepth)
        ])

        return report
    }

    /// Re-drives operations a terminated process abandoned in flight.
    ///
    /// Runs at launch, before any new work. Each carries its original idempotency key, so
    /// the server replays its stored response rather than applying the effect twice. This
    /// is the mechanism that makes "the app was killed mid-sync" a non-event.
    public func reconcileAfterLaunch() async throws -> Int {
        let orphaned = try await queue.orphanedInFlight()

        for var operation in orphaned {
            operation.requeueAfterTermination()
            try await queue.update(operation)
        }

        if orphaned.isEmpty == false {
            telemetry.event("sync.reconciled_orphans", attributes: ["count": .count(orphaned.count)])
        }

        return orphaned.count
    }
}

/// Pull and push mechanics.
///
/// Split from the actor declaration so that the type's public surface reads as its
/// lifecycle (synchronize, reconcile) with the machinery beside it rather than inside it.
private extension SyncEngine {
    // MARK: - Pull

    func pull(into report: inout SyncReport) async throws -> Int {
        var applied = 0
        var pages = 0

        while pages < maximumPullPages {
            let cursor = try await cursors.cursor()
            let page = try await transport.pullChanges(since: cursor, limit: pageSize)

            for change in page.changes {
                try await apply(change, into: &report)
                applied += 1
            }

            // The cursor advances only after its page has been applied. Advancing first
            // would mean a crash mid-page silently skips changes, and nothing downstream
            // could detect the gap.
            try await cursors.setCursor(page.nextCursor)

            pages += 1
            guard page.hasMore else { break }
        }

        return applied
    }

    func apply(_ change: RemoteChange, into report: inout SyncReport) async throws {
        let pending = try await pendingOperations(forEntity: change.entityID)

        guard pending.isEmpty == false else {
            // Nothing local to reconcile against. The device is a cache for this entity,
            // so the server's version simply wins.
            report.appliedRemote += 1
            return
        }

        let localDirty = pending.reduce(into: Set<String>()) { $0.formUnion($1.dirtyFields) }
        let localClock = pending.map(\.hlc).max() ?? change.hlc

        let outcome = resolver.resolve(
            localDirtyFields: localDirty,
            remoteChangedFields: change.changedFields,
            localClock: localClock,
            remoteClock: change.hlc
        )

        if outcome.isClean {
            report.autoMerged += 1
        } else {
            report.conflicted += 1
            report.conflictedEntities.insert(change.entityID)
            telemetry.event("sync.conflict_detected", attributes: [
                "fields": .count(outcome.requiresHumanDecision.count)
            ])
        }

        report.outcomes[change.entityID] = outcome
    }

    func pendingOperations(forEntity entityID: String) async throws -> [SyncOperation] {
        // Everything queued for this entity in any state, because a backed-off or in-flight
        // operation still represents an unsent local edit that a remote change may overlap.
        try await queue.operations(forEntity: entityID)
    }

    // MARK: - Push

    func push(into report: inout SyncReport) async throws {
        let now = dateProvider.now
        let batch = try await queue.dispatchable(limit: batchSize, at: now)

        guard batch.isEmpty == false else { return }

        var dispatched: [SyncOperation] = []
        for var operation in batch {
            operation.markInFlight()
            try await queue.update(operation)
            dispatched.append(operation)
        }

        let results: [PushResult]
        do {
            results = try await transport.pushDeltas(dispatched)
        } catch {
            // The outcome is unknown, which is not the same as failed. Every operation
            // returns to pending with its key intact, and the server deduplicates if it
            // did in fact receive them.
            for var operation in dispatched {
                operation.markFailed(
                    code: "ERR-4602", policy: retryPolicy, now: now, random: random
                )
                operation.returnToPending()
                try await queue.update(operation)
            }
            report.transportFailures = dispatched.count
            throw error
        }

        for result in results {
            try await process(result, report: &report, now: now)
        }
    }

    func process(_ result: PushResult, report: inout SyncReport, now: Date) async throws {
        switch result {
        case .applied(let id, _):
            try await queue.remove(id: id)
            report.applied += 1

        case .replayed(let id, _):
            // The server had already applied this. Counted separately because a rising
            // replay rate is the signature of a client retry storm, and collapsing it into
            // "applied" hides exactly the thing an operator needs to see.
            try await queue.remove(id: id)
            report.replayed += 1

        case .conflict(let id, _, let fields):
            try await queue.remove(id: id)
            report.conflicted += 1
            report.serverConflictFields.formUnion(fields)

        case .rejected(let id, let code, let retryable):
            guard var operation = try await operation(withID: id) else {
                // The queue does not know this operation, which should be impossible: it
                // was dispatched from that queue moments ago. Counted rather than ignored,
                // because an operation that disappears between dispatch and result is
                // exactly the silent loss this system must not have.
                report.rejected += 1
                telemetry.error("ERR-4801", correlationID: nil)
                return
            }

            if retryable {
                operation.markFailed(code: code, policy: retryPolicy, now: now, random: random)
                report.retrying += 1
            } else {
                // Retrying a validation or authorization failure can never succeed, and on
                // a field device it spends battery on a guaranteed failure.
                operation.markFailed(
                    code: code,
                    policy: RetryPolicy(baseDelay: 1, maximumDelay: 1, maximumAttempts: 1),
                    now: now,
                    random: random
                )
                report.rejected += 1
            }

            try await queue.update(operation)
        }
    }

    func operation(withID id: OperationID) async throws -> SyncOperation? {
        try await queue.operation(id: id)
    }
}
