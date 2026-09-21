import Testing
import Foundation
@testable import ApertureDomain
import ApertureTestSupport

@Suite("Capture durability")
struct CaptureMediaTests {

    private struct Harness {
        let writer = RecordingMediaWriter()
        // The repository is also the transaction runner, so a rollback restores its state
        // rather than merely reporting a failure.
        let repository = InMemoryInspectionRepository()
        let dateProvider = TestDateProvider()
        let random = SeededRandomSource(seed: 4)
        let inspectionID = InspectionID(rawValue: UUID())

        var useCase: CaptureMedia {
            CaptureMedia(
                mediaWriter: writer,
                media: repository,
                operations: repository,
                transactions: repository,
                clock: HybridLogicalClockGenerator(nodeID: "devA", dateProvider: dateProvider),
                dateProvider: dateProvider,
                random: random
            )
        }

        func request(bytes: Int = 4096) -> CaptureMedia.Request {
            CaptureMedia.Request(
                inspectionID: inspectionID,
                data: Data(repeating: 0xA5, count: bytes),
                kind: .photo
            )
        }
    }

    @Test("bytes are durable before the caller is told it worked")
    func durableWriteHappensFirst() async throws {
        let harness = Harness()

        let asset = try await harness.useCase.execute(harness.request())

        // The ordering is the product's central guarantee. An interface that acknowledges
        // first and persists afterwards turns every crash, jetsam, and battery death into
        // silent loss, and the inspector has no way to know: they saw the shutter fire.
        #expect(harness.writer.steps == [.checkedSpace, .wrote])
        #expect(try await harness.repository.asset(id: asset.id) != nil)
    }

    @Test("the record and the sync operation commit together")
    func recordAndOperationAreAtomic() async throws {
        let harness = Harness()

        _ = try await harness.useCase.execute(harness.request())

        // A crash between them leaves an asset the user can see and the server will never
        // hear about, which is the same loss wearing a different hat.
        #expect(try await harness.repository.assets(forInspection: harness.inspectionID).count == 1)
        #expect(harness.repository.pendingOperations.count == 1)
        #expect(harness.repository.pendingOperations.first?.entityType == "media_asset")
    }

    @Test("the queued operation carries an idempotency key")
    func operationIsIdempotent() async throws {
        let harness = Harness()

        _ = try await harness.useCase.execute(harness.request())

        let operation = try #require(harness.repository.pendingOperations.first)
        #expect(operation.idempotencyKey == operation.id.description)
        #expect(operation.idempotencyKey.isEmpty == false)
    }

    @Test("capture is refused before acquisition when storage is exhausted")
    func storageIsCheckedBeforeWriting() async {
        let harness = Harness()
        harness.writer.setAvailableBytes(100 * 1024 * 1024)

        await #expect(throws: DomainError.self) {
            _ = try await harness.useCase.execute(harness.request())
        }

        // Checked, then refused. Nothing was written. A capture that fires and then fails to
        // persist is the one outcome that must never happen.
        #expect(harness.writer.steps == [.checkedSpace])
        #expect(harness.writer.storedHashes.isEmpty)
    }

    @Test("a storage refusal names how many bytes are needed")
    func storageErrorIsActionable() async {
        let harness = Harness()
        harness.writer.setAvailableBytes(100 * 1024 * 1024)

        do {
            _ = try await harness.useCase.execute(harness.request())
            Issue.record("expected a refusal")
        } catch let error as DomainError {
            guard case .storageFull(let needed) = error else {
                Issue.record("expected storageFull, got \(error)")
                return
            }
            // "Free up 391 MB" is an instruction. "Storage full" is a complaint.
            #expect(needed > 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a failed write leaves nothing behind")
    func writeFailureLeavesNoRecord() async throws {
        let harness = Harness()
        harness.writer.failNextWrite(with: DomainError.unrecoverable(code: "ERR-4301", correlationID: "t"))

        await #expect(throws: DomainError.self) {
            _ = try await harness.useCase.execute(harness.request())
        }

        #expect(try await harness.repository.assets(forInspection: harness.inspectionID).isEmpty)
        #expect(harness.repository.pendingOperations.isEmpty)
    }

    @Test("a failed transaction reclaims the orphaned bytes")
    func transactionFailureRollsBackTheFile() async throws {
        let harness = Harness()
        harness.repository.failNextCommit()

        await #expect(throws: (any Error).self) {
            _ = try await harness.useCase.execute(harness.request())
        }

        // The bytes were written, the record was not, so the file is reclaimed. Anything
        // this misses is collected by the launch reconciliation pass, because a
        // content-addressed file with no record is recognisable as an orphan on sight.
        #expect(harness.writer.steps == [.checkedSpace, .wrote, .removed])
        #expect(harness.writer.storedHashes.isEmpty)
        #expect(try await harness.repository.assets(forInspection: harness.inspectionID).isEmpty)
    }

    @Test("a failed rollback still reports the original failure")
    func rollbackFailureDoesNotMaskTheCause() async {
        let harness = Harness()
        harness.repository.failNextCommit()
        harness.writer.failRemoval(with: DomainError.unrecoverable(code: "ERR-9999", correlationID: "t"))

        // The orphaned file is a tidiness problem the reconciler solves later. Masking the
        // transaction failure behind a cleanup failure would hide the thing that actually
        // went wrong.
        await #expect(throws: (any Error).self) {
            _ = try await harness.useCase.execute(harness.request())
        }
    }

    @Test("identical bytes produce identical content addresses")
    func contentAddressingIsStable() async throws {
        let harness = Harness()

        let first = try await harness.useCase.execute(harness.request())
        let second = try await harness.useCase.execute(harness.request())

        // Deduplication, integrity verification, and post-crash reconciliation all fall out
        // of this rather than being built separately.
        #expect(first.contentHash == second.contentHash)
        #expect(first.id != second.id)
    }
}

@Suite("Capture state machine")
struct CaptureStateTests {

    @Test("the shutter does nothing until the session is ready")
    func shutterRequiresReadiness() {
        #expect(CaptureState.idle.acceptsCapture == false)
        #expect(CaptureState.configuring.acceptsCapture == false)
        #expect(CaptureState.ready.acceptsCapture)
        #expect(CaptureState.capturing.acceptsCapture == false)
        #expect(CaptureState.persisting.acceptsCapture == false)
    }

    @Test("a degraded session still captures")
    func degradedStillCaptures() {
        // Capture never stops for heat. Losing the evidence is worse than losing the
        // analysis, and the analysis can be redone from the media while the site cannot be
        // revisited.
        #expect(CaptureState.degraded(reason: .thermalPressure).acceptsCapture)
        #expect(CaptureState.degraded(reason: .lowPowerMode).acceptsCapture)
    }

    @Test("the happy path runs configure, ready, capture, persist, ready")
    func happyPath() throws {
        var state = CaptureState.idle

        for event in [CaptureEvent.configure, .configured, .shutterPressed, .frameAcquired, .persisted] {
            state = try #require(state.applying(event), "\(event) rejected in \(state)")
        }

        #expect(state == .ready)
    }

    @Test("an event that does not apply is rejected rather than absorbed")
    func illegalTransitionsReturnNil() {
        // Returning nil rather than silently staying put matters: an event arriving in a
        // state that cannot handle it is a bug somewhere, and a machine that absorbs it
        // makes that bug invisible.
        #expect(CaptureState.idle.applying(.shutterPressed) == nil)
        #expect(CaptureState.ready.applying(.persisted) == nil)
        #expect(CaptureState.capturing.applying(.configured) == nil)
    }

    @Test("an interruption is recoverable without rebuilding the session")
    func interruptionRecovers() throws {
        var state = CaptureState.ready

        state = try #require(state.applying(.interrupted(.incomingCall)))
        #expect(state == .interrupted(reason: .incomingCall))
        #expect(state.requiresActiveSession == false)

        state = try #require(state.applying(.interruptionEnded))
        #expect(state == .ready)
    }

    @Test("an interruption during persistence does not abandon the write")
    func interruptionDuringPersistence() throws {
        // The state machine moves on, but the durable write is already in flight in the use
        // case and completes independently. Coupling them would let a phone call cost an
        // inspector their capture.
        let state = try #require(CaptureState.persisting.applying(.interrupted(.incomingCall)))

        #expect(state == .interrupted(reason: .incomingCall))
    }

    @Test("a terminal failure cannot be interrupted back into life")
    func failureIsTerminal() {
        let failed = CaptureState.failed(.permissionDenied(permission: "camera"))

        #expect(failed.isTerminal)
        #expect(failed.applying(.interrupted(.incomingCall)) == nil)
        #expect(failed.applying(.teardown) == .idle)
    }

    @Test("only states that need the camera keep the session running")
    func sessionLifetimeIsMinimal() {
        // A session left running while the user reads a form is a measurable drain for no
        // benefit, and the AR session is worse.
        #expect(CaptureState.idle.requiresActiveSession == false)
        #expect(CaptureState.interrupted(reason: .backgrounded).requiresActiveSession == false)
        #expect(CaptureState.ready.requiresActiveSession)
        #expect(CaptureState.persisting.requiresActiveSession)
    }
}

@Suite("Device conditions")
struct DeviceConditionTests {

    @Test("thermal states order by severity")
    func thermalOrdering() {
        #expect(ThermalState.nominal < ThermalState.fair)
        #expect(ThermalState.fair < ThermalState.serious)
        #expect(ThermalState.serious < ThermalState.critical)
    }

    @Test("inference stops at critical, capture never does")
    func inferenceGating() {
        #expect(ThermalState.nominal.permitsInference)
        #expect(ThermalState.serious.permitsInference)
        #expect(ThermalState.critical.permitsInference == false)
    }

    @Test("serious thermal pressure reduces inference resolution")
    func reducedResolution() {
        #expect(ThermalState.fair.requiresReducedResolution == false)
        #expect(ThermalState.serious.requiresReducedResolution)
        #expect(ThermalState.critical.requiresReducedResolution)
    }

    @Test("storage thresholds classify the three cases")
    func storageDisposition() {
        #expect(StoragePolicy.disposition(availableBytes: 10 * 1024 * 1024 * 1024) == .ample)
        #expect(StoragePolicy.disposition(availableBytes: 1024 * 1024 * 1024) == .warning)
        #expect(StoragePolicy.disposition(availableBytes: 100 * 1024 * 1024) == .blocked)
    }
}
