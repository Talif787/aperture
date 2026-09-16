import Foundation

/// The aggregate root.
///
/// Every mutation to a finding, a form value, or a media attachment goes through this
/// type. That is what makes the invariants below enforceable in one reviewable place
/// instead of at every call site that happens to touch an inspection.
///
/// The invariants, and where each is enforced:
///
/// - An inspection past `draft` or `changesRequested` is immutable on the device, because
///   the server is authoritative for status and a stale device must not overwrite a
///   reviewer's approval. Enforced by `requireEditable()` on every mutation.
/// - The template version is fixed at creation and never changes, so a template published
///   mid-inspection cannot alter work already in progress. Enforced by the type: it is a
///   `let`.
/// - Submission requires no unresolved conflicts and no missing required fields. Enforced
///   by `submit(requiredFieldKeys:clock:)`, which reports every gap at once rather than
///   one at a time.
/// - Every mutation stamps a clock and records which fields changed. Enforced by routing
///   all writes through `SyncMetadata`.
public struct Inspection: Sendable, Equatable, Identifiable, Codable {
    public let id: InspectionID
    public let tenantID: TenantID
    public let templateID: TemplateID
    public let templateVersion: Int
    public let createdAt: Date

    public private(set) var assignedUserID: UserID?
    public private(set) var status: Status
    public private(set) var formValues: [String: FormValue]
    public private(set) var findings: [FindingID: Finding]
    public private(set) var mediaAssets: Set<MediaID>
    public private(set) var sync: SyncMetadata

    /// The workflow states, and the only legal transitions between them.
    public enum Status: String, Sendable, Codable, CaseIterable {
        case draft
        case submitted
        case approved
        case changesRequested
        case rejected
        case voided

        /// Transitions the client may propose. The server re-validates every one of
        /// them, because the client is untrusted and its view of status may be stale.
        public func canTransition(to next: Status) -> Bool {
            switch (self, next) {
            case (.draft, .submitted),
                 (.submitted, .approved),
                 (.submitted, .changesRequested),
                 (.submitted, .rejected),
                 (.changesRequested, .submitted):
                return true
            case (.draft, .voided), (.submitted, .voided),
                 (.approved, .voided), (.rejected, .voided),
                 (.changesRequested, .voided):
                // Voiding is an audited administrative action, never a deletion.
                return true
            default:
                return false
            }
        }

        /// Whether the inspector may still change content in this state.
        public var permitsEditing: Bool {
            self == .draft || self == .changesRequested
        }
    }

    public enum Field {
        public static let status = "status"
        public static let assignedUser = "assigned_user_id"
        public static func formValue(_ key: String) -> String { "form.\(key)" }
    }

    public init(
        id: InspectionID,
        tenantID: TenantID,
        templateID: TemplateID,
        templateVersion: Int,
        assignedUserID: UserID?,
        createdAt: Date,
        clock: HybridLogicalClock
    ) {
        precondition(templateVersion > 0, "a template version is assigned at publication and starts at one")
        self.id = id
        self.tenantID = tenantID
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.assignedUserID = assignedUserID
        self.createdAt = createdAt
        self.status = .draft
        self.formValues = [:]
        self.findings = [:]
        self.mediaAssets = []
        self.sync = SyncMetadata(hlc: clock)
    }

    // MARK: - Derived state

    /// Findings waiting on a human decision. Submission is blocked while any exist.
    public var conflictedFindings: [Finding] {
        findings.values.filter { $0.conflictState.isPending }.sorted { $0.id < $1.id }
    }

    public var isEditable: Bool {
        status.permitsEditing && sync.isDeleted == false
    }

    // MARK: - Mutations

    public mutating func setFormValue(
        _ value: FormValue,
        forKey key: String,
        clock: HybridLogicalClock
    ) throws {
        try requireEditable()
        guard formValues[key] != value else { return }
        formValues[key] = value
        sync.markDirty([Field.formValue(key)], at: clock)
    }

    public mutating func addFinding(_ finding: Finding, clock: HybridLogicalClock) throws {
        try requireEditable()
        guard finding.inspectionID == id else {
            throw DomainError.validation([
                FieldError(fieldKey: "inspection_id", reason: .unsupportedValue)
            ])
        }
        findings[finding.id] = finding
        sync.markDirty(["findings"], at: clock)
    }

    /// Applies a change to a finding through the aggregate, so the editability invariant
    /// holds for findings as well as for the inspection itself.
    public mutating func updateFinding(
        id findingID: FindingID,
        clock: HybridLogicalClock,
        _ mutate: (inout Finding) -> Void
    ) throws {
        try requireEditable()
        guard var finding = findings[findingID] else {
            throw DomainError.notDownloaded(entity: "finding \(findingID)")
        }
        mutate(&finding)
        findings[findingID] = finding
        sync.markDirty(["findings"], at: clock)
    }

    public mutating func attachMedia(_ mediaID: MediaID, clock: HybridLogicalClock) throws {
        try requireEditable()
        guard mediaAssets.contains(mediaID) == false else { return }
        mediaAssets.insert(mediaID)
        sync.markDirty(["media"], at: clock)
    }

    /// Attempts the transition to `submitted`.
    ///
    /// Reports every blocking problem at once. A submission flow that surfaces one missing
    /// field at a time is a flow that sends an inspector back into an attic three times.
    public mutating func submit(
        requiredFieldKeys: Set<String>,
        clock: HybridLogicalClock
    ) throws {
        guard status.canTransition(to: .submitted) else {
            throw DomainError.illegalStateTransition(from: status.rawValue, to: Status.submitted.rawValue)
        }

        let conflicts = conflictedFindings
        guard conflicts.isEmpty else {
            throw DomainError.conflictRequiresResolution(
                entity: "inspection \(id)",
                conflictingFields: conflicts.flatMap { finding -> [String] in
                    guard case .pending(let fields) = finding.conflictState else { return [] }
                    return fields.sorted()
                }
            )
        }

        let missing = requiredFieldKeys
            .filter { key in
                guard let value = formValues[key] else { return true }
                return value.isEmpty
            }
            .sorted()

        guard missing.isEmpty else {
            throw DomainError.validation(missing.map { FieldError(fieldKey: $0, reason: .required) })
        }

        status = .submitted
        sync.markDirty([Field.status], at: clock)
    }

    /// Applies a status change that originated on the server.
    ///
    /// Separate from `submit` on purpose: the server is authoritative for status, so this
    /// path does not re-check the transition against local state, which may be stale.
    public mutating func applyServerStatus(
        _ newStatus: Status,
        serverVersion: Int64,
        clock: HybridLogicalClock,
        at instant: Date
    ) {
        status = newStatus
        sync.adoptServerState(serverVersion: serverVersion, clock: clock, at: instant)
    }

    public mutating func markDeleted(at instant: Date, clock: HybridLogicalClock) throws {
        guard status == .draft else {
            // A submitted inspection is part of a business record. Removing it is an
            // administrative void, which is audited, not a delete.
            throw DomainError.illegalStateTransition(from: status.rawValue, to: "deleted")
        }
        sync.markDeleted(at: instant, clock: clock)
    }

    private func requireEditable() throws {
        guard sync.isDeleted == false else {
            throw DomainError.illegalStateTransition(from: "deleted", to: "edited")
        }
        guard status.permitsEditing else {
            throw DomainError.illegalStateTransition(from: status.rawValue, to: "edited")
        }
    }
}

/// A value captured in a template-defined form field.
///
/// A closed set rather than `Any`, so the persistence layer, the wire format, and the
/// validation rules all agree on what can exist.
public enum FormValue: Sendable, Equatable, Codable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case choice(String)
    case date(Date)

    /// Whether this counts as unanswered for a required field.
    ///
    /// An empty string is absence, not an answer. A `false` boolean is an answer, which is
    /// why it is not treated the same way: "is the meter accessible" answered no is a
    /// complete response.
    public var isEmpty: Bool {
        switch self {
        case .text(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .choice(let value): return value.isEmpty
        case .number, .boolean, .date: return false
        }
    }
}
