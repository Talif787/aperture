import Foundation
import ApertureDomain

/// How a field behaves when two actors changed it at once.
public enum FieldConflictPolicy: String, Sendable, Equatable, CaseIterable {
    /// Deterministic, cheap, and genuinely low stakes. Ordered by hybrid logical clock,
    /// never by wall-clock time.
    case lastWriterWins

    /// Both contributions are kept and merged.
    case mergeText

    /// Two people adding evidence should union. Losing a photograph is worse than keeping
    /// a redundant one.
    case addWins

    /// The server decides, regardless of what the device believes. Used for workflow
    /// state, where a stale device must not overwrite a reviewer's approval.
    case serverAuthoritative

    /// Neither value is discarded and neither is chosen. A person decides.
    case requiresHumanDecision
}

/// The per-field policy table.
///
/// This table is the one place where a product decision constrains the architecture rather
/// than the other way round. Automatically resolving a disputed damage measurement would
/// be easy and would make sync simpler, and it is not permitted: the number ends up in a
/// document that settles an insurance claim, and silently choosing between two of them
/// creates financial and legal exposure that no amount of convergence guarantees offsets.
public struct ConflictPolicyTable: Sendable {
    private let policies: [String: FieldConflictPolicy]
    private let fallback: FieldConflictPolicy

    public init(
        policies: [String: FieldConflictPolicy],
        fallback: FieldConflictPolicy = .lastWriterWins
    ) {
        self.policies = policies
        self.fallback = fallback
    }

    /// The production table.
    public static let standard = ConflictPolicyTable(policies: [
        Finding.Field.measurement: .requiresHumanDecision,
        Finding.Field.defectClass: .requiresHumanDecision,
        Finding.Field.severity: .requiresHumanDecision,
        Finding.Field.note: .mergeText,
        Finding.Field.attachedMedia: .addWins,
        Inspection.Field.status: .serverAuthoritative,
        Inspection.Field.assignedUser: .serverAuthoritative,
        "media": .addWins,
        "findings": .addWins
    ])

    public func policy(for fieldKey: String) -> FieldConflictPolicy {
        if let exact = policies[fieldKey] { return exact }

        // Template-defined form fields share a prefix and are ordinary scalars. A carrier
        // adding a field to a template must not have to also register a conflict policy,
        // so the fallback has to be safe for anything a template can hold.
        if fieldKey.hasPrefix("form.") { return fallback }

        return fallback
    }
}

/// What resolution decided, field by field.
public struct ConflictOutcome: Sendable, Equatable {
    /// Changed on one side only. Not a conflict at all, and the common case by a wide
    /// margin: two actors editing different fields of the same record.
    public var automaticallyMerged: Set<String> = []

    public var resolvedToLocal: Set<String> = []
    public var resolvedToRemote: Set<String> = []
    public var textMerged: Set<String> = []
    public var unioned: Set<String> = []

    /// Blocks submission until a person chooses. Both values are retained.
    public var requiresHumanDecision: Set<String> = []

    public var isClean: Bool { requiresHumanDecision.isEmpty }

    /// Fields the local device should now send, having won or merged them.
    public var fieldsToPush: Set<String> {
        resolvedToLocal.union(textMerged).union(unioned).union(automaticallyMerged)
    }
}

/// Applies the policy table to a concurrent change.
public struct ConflictResolver: Sendable {
    private let table: ConflictPolicyTable

    public init(table: ConflictPolicyTable = .standard) {
        self.table = table
    }

    /// Decides each field independently.
    ///
    /// The first thing it establishes is that a version mismatch is not by itself a
    /// conflict. Two actors editing different fields of the same record is concurrency,
    /// not disagreement, and treating it as a conflict would put a resolution prompt in
    /// front of an inspector several times a shift for no reason. Only an *overlapping*
    /// field is a conflict.
    public func resolve(
        localDirtyFields: Set<String>,
        remoteChangedFields: Set<String>,
        localClock: HybridLogicalClock,
        remoteClock: HybridLogicalClock
    ) -> ConflictOutcome {
        var outcome = ConflictOutcome()

        outcome.automaticallyMerged = localDirtyFields.subtracting(remoteChangedFields)
        outcome.resolvedToRemote = remoteChangedFields.subtracting(localDirtyFields)

        for field in localDirtyFields.intersection(remoteChangedFields).sorted() {
            switch table.policy(for: field) {
            case .lastWriterWins:
                if remoteClock > localClock {
                    outcome.resolvedToRemote.insert(field)
                } else {
                    outcome.resolvedToLocal.insert(field)
                }
            case .mergeText:
                outcome.textMerged.insert(field)
            case .addWins:
                outcome.unioned.insert(field)
            case .serverAuthoritative:
                outcome.resolvedToRemote.insert(field)
            case .requiresHumanDecision:
                outcome.requiresHumanDecision.insert(field)
            }
        }

        return outcome
    }
}
