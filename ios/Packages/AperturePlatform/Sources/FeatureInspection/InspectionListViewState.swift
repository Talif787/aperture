import Foundation
import ApertureDomain

/// The state of the inspection list screen.
///
/// Modeled as one closed enumeration rather than as a struct of optionals and booleans.
/// A `isLoading: Bool` alongside `error: Error?` and `items: [T]` makes several illegal
/// states representable, including loading-with-an-error and empty-versus-not-yet-loaded,
/// and in a long-lived app every representable illegal state eventually renders.
///
/// `offline` is a distinct case and is explicitly not an error. Working without
/// connectivity is the normal operating mode of this product, and presenting it as a
/// failure is the single fastest way to make a field tool feel broken.
public enum InspectionListViewState: Equatable, Sendable {
    case loading
    case content(InspectionListContent)
    case empty(EmptyReason)
    case failure(DomainError)

    public enum EmptyReason: Equatable, Sendable {
        case noAssignments
        case filteredOut
    }
}

/// The data rendered by the content case, including the sync posture that accompanies it.
public struct InspectionListContent: Equatable, Sendable {
    public let summaries: [InspectionSummary]
    public let syncPosture: SyncPosture
    /// When the server view of this list was last refreshed. Always displayed, so a user
    /// can tell the difference between "there is nothing" and "I have not heard recently".
    public let lastSyncedAt: Date?

    public init(summaries: [InspectionSummary], syncPosture: SyncPosture, lastSyncedAt: Date?) {
        self.summaries = summaries
        self.syncPosture = syncPosture
        self.lastSyncedAt = lastSyncedAt
    }
}

/// What the persistent, non-blocking sync indicator shows.
public enum SyncPosture: Equatable, Sendable {
    case upToDate
    case offline(pendingOperations: Int)
    case syncing(remaining: Int)
    case attentionRequired(deadLetteredOperations: Int)

    /// Whether the user must act. Only dead-lettered work qualifies; a growing queue on a
    /// device with no signal is expected and requires nothing from anyone.
    public var demandsUserAction: Bool {
        if case .attentionRequired = self { return true }
        return false
    }
}

/// A row in the list.
public struct InspectionSummary: Equatable, Sendable, Identifiable {
    public let id: InspectionID
    public let siteLabel: String
    public let templateName: String
    public let status: Status
    public let capturedMediaCount: Int
    public let hasUnresolvedConflict: Bool

    public enum Status: String, Equatable, Sendable {
        case draft
        case submitted
        case approved
        case changesRequested
        case rejected
    }

    public init(
        id: InspectionID,
        siteLabel: String,
        templateName: String,
        status: Status,
        capturedMediaCount: Int,
        hasUnresolvedConflict: Bool
    ) {
        self.id = id
        self.siteLabel = siteLabel
        self.templateName = templateName
        self.status = status
        self.capturedMediaCount = capturedMediaCount
        self.hasUnresolvedConflict = hasUnresolvedConflict
    }
}
