import Foundation
import ApertureDomain

/// What one cycle did. Returned rather than logged, so a caller can render it and a test
/// can assert on it.
public struct SyncReport: Sendable, Equatable {
    public var pulled: Int = 0
    public var appliedRemote: Int = 0
    public var autoMerged: Int = 0
    public var conflicted: Int = 0
    public var applied: Int = 0
    public var replayed: Int = 0
    public var retrying: Int = 0
    public var rejected: Int = 0
    public var transportFailures: Int = 0
    public var queueDepth: Int = 0
    public var deadLettered: Int = 0
    public var conflictedEntities: Set<String> = []
    public var serverConflictFields: Set<String> = []
    public var outcomes: [String: ConflictOutcome] = [:]

    /// Whether anything needs a person. The only part of this report a user ever sees.
    public var requiresAttention: Bool {
        conflicted > 0 || deadLettered > 0
    }

    public init() {}
}
