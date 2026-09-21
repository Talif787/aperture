import Foundation
import ApertureDomain

/// Free text that two people can edit at once without either losing their words.
///
/// A conflict-free replicated data type, specifically a grow-only set of timestamped
/// segments with a deterministic order. The architecture already called for
/// "union of edits" on notes, and union-of-edits *is* a CRDT: implementing it as one
/// rather than approximating it with a merge heuristic is the difference between a rule
/// that always holds and one that usually does.
///
/// The three properties that make it safe to merge without coordination are commutativity,
/// associativity, and idempotence. Replicas that receive the same edits in different
/// orders, grouped differently, or more than once all arrive at the same text. Each is
/// asserted in the test suite, because a merge that is only usually commutative produces
/// divergence that appears days later and cannot be reproduced.
public struct MergeableNote: Sendable, Equatable, Codable {
    /// One contribution. Immutable once created, which is what makes the set grow-only.
    public struct Segment: Sendable, Equatable, Codable, Comparable, Identifiable {
        public let text: String
        public let hlc: HybridLogicalClock
        public let authorID: String

        /// Composite of clock, author, and text.
        ///
        /// Deriving it from the clock alone was wrong, and wrong in the worst way a CRDT
        /// can be. Two segments sharing a clock collided, the second was treated as a
        /// duplicate, and one author's words vanished. Merging then depended on arrival
        /// order and the type stopped being a CRDT at all.
        ///
        /// In production the clock carries a node identifier, so a collision needed a
        /// caller whose `authorID` disagreed with `hlc.nodeID`, which nothing enforces.
        /// Relying on that discipline to prevent silent data loss was the mistake. The
        /// composite makes the guarantee structural: identical edits still deduplicate,
        /// and distinct edits cannot collide regardless of how the clock was built.
        public var id: String { "\(hlc.description)|\(authorID)|\(text)" }

        public init(text: String, hlc: HybridLogicalClock, authorID: String) {
            self.text = text
            self.hlc = hlc
            self.authorID = authorID
        }

        /// Ordered by clock, then by author.
        ///
        /// The author tiebreak matters even though clocks carry a node identifier: it keeps
        /// the ordering total and therefore the rendered text identical on every replica.
        /// A merge that is deterministic in content but not in order still shows two
        /// inspectors different paragraphs.
        public static func < (lhs: Segment, rhs: Segment) -> Bool {
            if lhs.hlc != rhs.hlc { return lhs.hlc < rhs.hlc }
            return lhs.authorID < rhs.authorID
        }
    }

    public private(set) var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments.sorted()
    }

    /// The text a person reads.
    public var rendered: String {
        segments.map(\.text).joined(separator: "\n\n")
    }

    public var isEmpty: Bool { segments.isEmpty }

    public mutating func append(_ text: String, hlc: HybridLogicalClock, authorID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        insert(Segment(text: trimmed, hlc: hlc, authorID: authorID))
    }

    private mutating func insert(_ segment: Segment) {
        guard segments.contains(where: { $0.id == segment.id }) == false else { return }
        segments.append(segment)
        segments.sort()
    }

    /// Unions two replicas.
    ///
    /// Nothing is dropped and nothing is overwritten, which is the whole point: the two
    /// authors of a disputed note are an inspector who was on site and a reviewer who was
    /// not, and neither of their observations is safe to discard automatically.
    public func merged(with other: MergeableNote) -> MergeableNote {
        var combined = self
        for segment in other.segments {
            combined.insert(segment)
        }
        return combined
    }

    /// Builds a single-segment note, for text that has never been merged.
    public static func single(
        _ text: String,
        hlc: HybridLogicalClock,
        authorID: String
    ) -> MergeableNote {
        var note = MergeableNote()
        note.append(text, hlc: hlc, authorID: authorID)
        return note
    }
}
