import Testing
import Foundation
@testable import ApertureDomain
import ApertureTestSupport

/// Shared setup, lifted out of the suites so each one stays focused on a single concern.
private struct Fixture {
    let clockGenerator: HybridLogicalClockGenerator
    let dateProvider: TestDateProvider
    let random: SeededRandomSource

    init(seed: UInt64 = 1) {
        dateProvider = TestDateProvider()
        random = SeededRandomSource(seed: seed)
        clockGenerator = HybridLogicalClockGenerator(nodeID: "devA", dateProvider: dateProvider)
    }

    func makeInspection() -> Inspection {
        Inspection(
            id: InspectionID(generatedAt: dateProvider.now, random: random),
            tenantID: TenantID(generatedAt: dateProvider.now, random: random),
            templateID: TemplateID(generatedAt: dateProvider.now, random: random),
            templateVersion: 3,
            assignedUserID: nil,
            createdAt: dateProvider.now,
            clock: clockGenerator.send()
        )
    }

    func makeFinding(in inspection: Inspection, defectClass: String = "hail_bruising") -> Finding {
        Finding(
            id: FindingID(generatedAt: dateProvider.now, random: random),
            inspectionID: inspection.id,
            defectClass: defectClass,
            clock: clockGenerator.send()
        )
    }
}

@Suite("Inspection editability")
struct InspectionEditabilityTests {

    @Test("a draft accepts edits")
    func draftIsEditable() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()

        try inspection.setFormValue(.text("south slope"), forKey: "location", clock: fixture.clockGenerator.send())

        #expect(inspection.formValues["location"] == .text("south slope"))
        #expect(inspection.sync.dirtyFields.contains("form.location"))
    }

    @Test("a non-editable status rejects edits", arguments: [
        Inspection.Status.submitted, .approved, .rejected, .voided
    ])
    func nonEditableStatusesRejectEdits(status: Inspection.Status) throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        inspection.applyServerStatus(
            status,
            serverVersion: 4,
            clock: fixture.clockGenerator.send(),
            at: fixture.dateProvider.now
        )

        #expect(throws: DomainError.self) {
            try inspection.setFormValue(.text("x"), forKey: "location", clock: fixture.clockGenerator.send())
        }
    }

    @Test("changes requested reopens editing")
    func changesRequestedIsEditable() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        inspection.applyServerStatus(
            .changesRequested,
            serverVersion: 5,
            clock: fixture.clockGenerator.send(),
            at: fixture.dateProvider.now
        )

        try inspection.setFormValue(.number(12), forKey: "count", clock: fixture.clockGenerator.send())

        #expect(inspection.isEditable)
    }

    @Test("only the documented status transitions are legal")
    func statusTransitions() {
        #expect(Inspection.Status.draft.canTransition(to: .submitted))
        #expect(Inspection.Status.submitted.canTransition(to: .approved))
        #expect(Inspection.Status.submitted.canTransition(to: .changesRequested))
        #expect(Inspection.Status.changesRequested.canTransition(to: .submitted))

        // An approved inspection is a business record. It is voided, never reopened.
        #expect(Inspection.Status.approved.canTransition(to: .draft) == false)
        #expect(Inspection.Status.draft.canTransition(to: .approved) == false)
        #expect(Inspection.Status.rejected.canTransition(to: .submitted) == false)
    }
}

@Suite("Inspection submission")
struct InspectionSubmissionTests {

    @Test("submission reports every missing required field at once")
    func submissionReportsAllGaps() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        try inspection.setFormValue(.text("present"), forKey: "roof_type", clock: fixture.clockGenerator.send())

        do {
            try inspection.submit(
                requiredFieldKeys: ["roof_type", "slope", "age_years", "access_notes"],
                clock: fixture.clockGenerator.send()
            )
            Issue.record("submission should have failed")
        } catch let error as DomainError {
            guard case .validation(let fields) = error else {
                Issue.record("expected a validation failure, got \(error)")
                return
            }
            // All three at once. Reporting one at a time sends an inspector back into an
            // attic three separate times.
            #expect(fields.count == 3)
            #expect(Set(fields.map(\.fieldKey)) == ["slope", "age_years", "access_notes"])
        }
    }

    @Test("an empty string does not satisfy a required field")
    func whitespaceIsNotAnAnswer() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        try inspection.setFormValue(.text("   "), forKey: "notes", clock: fixture.clockGenerator.send())

        #expect(throws: DomainError.self) {
            try inspection.submit(requiredFieldKeys: ["notes"], clock: fixture.clockGenerator.send())
        }
    }

    @Test("a false boolean does satisfy a required field")
    func falseIsAnAnswer() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        try inspection.setFormValue(.boolean(false), forKey: "meter_accessible", clock: fixture.clockGenerator.send())

        try inspection.submit(requiredFieldKeys: ["meter_accessible"], clock: fixture.clockGenerator.send())

        #expect(inspection.status == .submitted)
    }

    @Test("an unresolved conflict blocks submission")
    func conflictBlocksSubmission() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        var finding = fixture.makeFinding(in: inspection)
        finding.markConflicted(fields: [Finding.Field.measurement])
        try inspection.addFinding(finding, clock: fixture.clockGenerator.send())

        do {
            try inspection.submit(requiredFieldKeys: [], clock: fixture.clockGenerator.send())
            Issue.record("submission should have been blocked")
        } catch let error as DomainError {
            guard case .conflictRequiresResolution(_, let fields) = error else {
                Issue.record("expected a conflict failure, got \(error)")
                return
            }
            #expect(fields.contains(Finding.Field.measurement))
        }
    }

    @Test("submission succeeds once the conflict is resolved")
    func resolvedConflictUnblocksSubmission() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        var finding = fixture.makeFinding(in: inspection)
        finding.markConflicted(fields: [Finding.Field.measurement])
        try inspection.addFinding(finding, clock: fixture.clockGenerator.send())

        try inspection.updateFinding(id: finding.id, clock: fixture.clockGenerator.send()) { target in
            target.resolveConflict(
                keptLocal: true,
                clock: HybridLogicalClock(wallClockMilliseconds: 1, counter: 0, nodeID: "devA")
            )
        }
        try inspection.submit(requiredFieldKeys: [], clock: fixture.clockGenerator.send())

        #expect(inspection.status == .submitted)
        #expect(inspection.conflictedFindings.isEmpty)
    }
}

@Suite("Inspection findings and deletion")
struct InspectionFindingTests {

    @Test("a finding belonging to another inspection is rejected")
    func findingIdentityIsChecked() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        let other = fixture.makeInspection()
        let stray = fixture.makeFinding(in: other)

        #expect(throws: DomainError.self) {
            try inspection.addFinding(stray, clock: fixture.clockGenerator.send())
        }
    }

    @Test("updating an absent finding fails rather than silently doing nothing")
    func updatingUnknownFindingFails() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        let absent = FindingID(generatedAt: fixture.dateProvider.now, random: fixture.random)

        #expect(throws: DomainError.self) {
            try inspection.updateFinding(id: absent, clock: fixture.clockGenerator.send()) { _ in }
        }
    }

    @Test("a draft can be deleted")
    func draftDeletion() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()

        try inspection.markDeleted(at: fixture.dateProvider.now, clock: fixture.clockGenerator.send())

        #expect(inspection.sync.isDeleted)
        #expect(inspection.isEditable == false)
    }

    @Test("a submitted inspection cannot be deleted")
    func submittedCannotBeDeleted() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        try inspection.submit(requiredFieldKeys: [], clock: fixture.clockGenerator.send())

        // A submitted inspection is part of a business record. Removing it is an audited
        // administrative void, not a delete.
        #expect(throws: DomainError.self) {
            try inspection.markDeleted(at: fixture.dateProvider.now, clock: fixture.clockGenerator.send())
        }
    }
}

@Suite("Sync metadata")
struct SyncMetadataTests {

    @Test("acknowledging clears only the fields the server accepted")
    func partialAcknowledgement() throws {
        let fixture = Fixture()
        var inspection = fixture.makeInspection()
        try inspection.setFormValue(.text("a"), forKey: "one", clock: fixture.clockGenerator.send())
        try inspection.setFormValue(.text("b"), forKey: "two", clock: fixture.clockGenerator.send())

        var sync = inspection.sync
        sync.acknowledge(
            serverVersion: 9,
            acceptedFields: [Inspection.Field.formValue("one")],
            at: fixture.dateProvider.now
        )

        // The edit made while the request was in flight stays dirty. Clearing everything
        // on acknowledgment is how an edit during a slow sync gets silently dropped.
        #expect(sync.dirtyFields == [Inspection.Field.formValue("two")])
        #expect(sync.serverVersion == 9)
        #expect(sync.hasPendingChanges)
    }

    @Test("an untouched entity is not locally authoritative")
    func authorityFollowsDirtyFields() {
        let fixture = Fixture()
        var sync = SyncMetadata(hlc: fixture.clockGenerator.send())

        #expect(sync.isLocallyAuthoritative == false)

        sync.markDirty(["field"], at: fixture.clockGenerator.send())

        #expect(sync.isLocallyAuthoritative)
    }
}
