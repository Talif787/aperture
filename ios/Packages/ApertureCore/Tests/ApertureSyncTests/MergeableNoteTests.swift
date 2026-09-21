import Testing
import Foundation
@testable import ApertureSync
import ApertureDomain
import ApertureTestSupport

@Suite("Mergeable note")
struct MergeableNoteTests {

    private func clock(_ milliseconds: UInt64, _ node: String = "devA") -> HybridLogicalClock {
        HybridLogicalClock(wallClockMilliseconds: milliseconds, counter: 0, nodeID: node)
    }

    private func note(_ text: String, _ milliseconds: UInt64, _ author: String) -> MergeableNote {
        .single(text, hlc: clock(milliseconds, author), authorID: author)
    }

    @Test("merging keeps both contributions")
    func nothingIsLost() {
        let inspector = note("Hail bruising on the south slope.", 1000, "devA")
        let reviewer = note("Extent looks larger than recorded.", 2000, "devB")

        let merged = inspector.merged(with: reviewer)

        // The two authors of a disputed note are an inspector who was on site and a
        // reviewer who was not. Neither observation is safe to discard automatically.
        #expect(merged.segments.count == 2)
        #expect(merged.rendered.contains("Hail bruising"))
        #expect(merged.rendered.contains("Extent looks larger"))
    }

    @Test("merge is commutative")
    func commutative() {
        let first = note("A", 1000, "devA")
        let second = note("B", 2000, "devB")

        // Replicas receive edits in whatever order the network delivers them. If order
        // changed the result, two devices would show different text and neither would be
        // wrong.
        #expect(first.merged(with: second) == second.merged(with: first))
    }

    @Test("merge is associative")
    func associative() {
        let first = note("A", 1000, "devA")
        let second = note("B", 2000, "devB")
        let third = note("C", 3000, "devC")

        // Grouping is not something replicas agree on either: one device may merge two
        // edits before a third arrives, another may receive all three at once.
        #expect(first.merged(with: second).merged(with: third)
                == first.merged(with: second.merged(with: third)))
    }

    @Test("merge is idempotent")
    func idempotent() {
        let first = note("A", 1000, "devA")
        let second = note("B", 2000, "devB")
        let once = first.merged(with: second)

        // At-least-once delivery means the same edit arrives twice routinely. A merge that
        // duplicated on re-delivery would grow a note every time the network stuttered.
        #expect(once.merged(with: second) == once)
        #expect(once.merged(with: once) == once)
    }

    @Test("ordering is identical on every replica", arguments: [1, 7, 99, 2026])
    func deterministicOrdering(seed: UInt64) {
        let random = SeededRandomSource(seed: seed)
        let authors = ["devA", "devB", "devC"]

        var segments: [MergeableNote.Segment] = []
        for index in 0..<30 {
            let author = authors[Int(random.value(upperBound: 3))]
            segments.append(
                MergeableNote.Segment(
                    text: "segment-\(index)",
                    hlc: clock(UInt64(1000 + index * 10), author),
                    authorID: author
                )
            )
        }

        // Build the same note from the segments in two different arrival orders.
        var forward = MergeableNote()
        for segment in segments {
            forward = forward.merged(with: MergeableNote(segments: [segment]))
        }
        var backward = MergeableNote()
        for segment in segments.reversed() {
            backward = backward.merged(with: MergeableNote(segments: [segment]))
        }

        // A merge that is deterministic in content but not in order still shows two
        // inspectors different paragraphs.
        #expect(forward.rendered == backward.rendered)
    }

    @Test("two authors writing in the same millisecond still order deterministically")
    func authorBreaksTies() {
        let shared = clock(5000, "devA")
        let alpha = MergeableNote(segments: [
            MergeableNote.Segment(text: "alpha", hlc: shared, authorID: "devA")
        ])
        let beta = MergeableNote(segments: [
            MergeableNote.Segment(text: "beta", hlc: shared, authorID: "devB")
        ])

        #expect(alpha.merged(with: beta).rendered == beta.merged(with: alpha).rendered)
    }

    @Test("two authors sharing a clock both survive the merge")
    func identicalClocksDoNotCollide() {
        let shared = clock(5000, "devA")
        let alpha = MergeableNote(segments: [
            MergeableNote.Segment(text: "alpha", hlc: shared, authorID: "devA")
        ])
        let beta = MergeableNote(segments: [
            MergeableNote.Segment(text: "beta", hlc: shared, authorID: "devB")
        ])

        let merged = alpha.merged(with: beta)

        // Segment identity used to come from the clock alone, so these two collided and
        // one author's words vanished. Silent loss is the one thing a CRDT must never do,
        // and it made merging depend on arrival order.
        #expect(merged.segments.count == 2)
        #expect(merged.rendered.contains("alpha"))
        #expect(merged.rendered.contains("beta"))
    }

    @Test("an identical edit delivered twice still deduplicates")
    func identicalEditsStillDedup() {
        let shared = clock(5000, "devA")
        let segment = MergeableNote.Segment(text: "same", hlc: shared, authorID: "devA")
        let note = MergeableNote(segments: [segment])

        // The composite identity must not break idempotence: at-least-once delivery means
        // the same edit arrives twice routinely.
        #expect(note.merged(with: MergeableNote(segments: [segment])).segments.count == 1)
    }

    @Test("empty contributions are ignored")
    func emptyIsNotASegment() {
        var subject = MergeableNote()
        subject.append("   \n  ", hlc: clock(1000), authorID: "devA")

        #expect(subject.isEmpty)
    }
}

@Suite("Conflict policy")
struct ConflictResolverTests {

    private let resolver = ConflictResolver()

    private func clock(_ milliseconds: UInt64, _ node: String = "devA") -> HybridLogicalClock {
        HybridLogicalClock(wallClockMilliseconds: milliseconds, counter: 0, nodeID: node)
    }

    @Test("editing different fields is not a conflict")
    func disjointFieldsMergeAutomatically() {
        let outcome = resolver.resolve(
            localDirtyFields: [Finding.Field.note],
            remoteChangedFields: [Finding.Field.severity],
            localClock: clock(1000),
            remoteClock: clock(2000, "srv1")
        )

        // The common case by a wide margin. Treating it as a conflict would put a
        // resolution prompt in front of an inspector several times a shift for no reason.
        #expect(outcome.isClean)
        #expect(outcome.automaticallyMerged == [Finding.Field.note])
        #expect(outcome.resolvedToRemote == [Finding.Field.severity])
    }

    @Test("a measurement is never resolved automatically")
    func measurementsRequireAPerson() {
        let outcome = resolver.resolve(
            localDirtyFields: [Finding.Field.measurement],
            remoteChangedFields: [Finding.Field.measurement],
            localClock: clock(9999),
            remoteClock: clock(1000, "srv1")
        )

        // Even with a decisively newer local clock. The number ends up in a document that
        // settles a claim, and silently choosing between two of them is exposure that no
        // convergence guarantee offsets.
        #expect(outcome.requiresHumanDecision == [Finding.Field.measurement])
        #expect(outcome.isClean == false)
    }

    @Test("classification fields also require a person", arguments: [
        Finding.Field.defectClass, Finding.Field.severity
    ])
    func classificationsRequireAPerson(field: String) {
        let outcome = resolver.resolve(
            localDirtyFields: [field],
            remoteChangedFields: [field],
            localClock: clock(1000),
            remoteClock: clock(2000, "srv1")
        )

        #expect(outcome.requiresHumanDecision == [field])
    }

    @Test("notes merge rather than compete")
    func notesMerge() {
        let outcome = resolver.resolve(
            localDirtyFields: [Finding.Field.note],
            remoteChangedFields: [Finding.Field.note],
            localClock: clock(1000),
            remoteClock: clock(2000, "srv1")
        )

        #expect(outcome.textMerged == [Finding.Field.note])
        #expect(outcome.isClean)
    }

    @Test("media unions, because losing evidence is worse than keeping extra")
    func mediaAddWins() {
        let outcome = resolver.resolve(
            localDirtyFields: [Finding.Field.attachedMedia],
            remoteChangedFields: [Finding.Field.attachedMedia],
            localClock: clock(2000),
            remoteClock: clock(1000, "srv1")
        )

        #expect(outcome.unioned == [Finding.Field.attachedMedia])
    }

    @Test("status is server-authoritative even when the device is newer")
    func statusIsServerAuthoritative() {
        let outcome = resolver.resolve(
            localDirtyFields: [Inspection.Field.status],
            remoteChangedFields: [Inspection.Field.status],
            localClock: clock(9999),
            remoteClock: clock(1000, "srv1")
        )

        // A device that has been offline for two days must not overwrite a reviewer's
        // approval with a stale local transition.
        #expect(outcome.resolvedToRemote == [Inspection.Field.status])
    }

    @Test("a scalar field is decided by the hybrid logical clock, not by wall time")
    func scalarsUseTheHybridClock() {
        let localNewer = resolver.resolve(
            localDirtyFields: ["form.access_notes"],
            remoteChangedFields: ["form.access_notes"],
            localClock: clock(5000),
            remoteClock: clock(1000, "srv1")
        )
        let remoteNewer = resolver.resolve(
            localDirtyFields: ["form.access_notes"],
            remoteChangedFields: ["form.access_notes"],
            localClock: clock(1000),
            remoteClock: clock(5000, "srv1")
        )

        #expect(localNewer.resolvedToLocal == ["form.access_notes"])
        #expect(remoteNewer.resolvedToRemote == ["form.access_notes"])
    }

    @Test("a template field nobody registered a policy for still resolves safely")
    func unknownFieldsFallBack() {
        let outcome = resolver.resolve(
            localDirtyFields: ["form.brand_new_field"],
            remoteChangedFields: ["form.brand_new_field"],
            localClock: clock(2000),
            remoteClock: clock(1000, "srv1")
        )

        // A carrier adding a field to a template must not also have to register a conflict
        // policy, so the fallback has to be safe for anything a template can hold.
        #expect(outcome.isClean)
        #expect(outcome.resolvedToLocal == ["form.brand_new_field"])
    }
}
