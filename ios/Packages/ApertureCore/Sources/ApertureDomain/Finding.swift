import Foundation

/// A recorded defect or observation within an inspection.
///
/// The conflict state lives on the finding rather than on the inspection, because
/// conflicts are per field and blocking an entire inspection over one disputed
/// measurement would stop work that has nothing to do with it.
public struct Finding: Sendable, Equatable, Identifiable, Codable {
    public let id: FindingID
    public let inspectionID: InspectionID

    public private(set) var defectClass: String
    public private(set) var severity: Severity?
    public private(set) var measurement: SiteMeasurement?
    public private(set) var note: String
    public private(set) var attachedMedia: Set<MediaID>
    public private(set) var conflictState: ConflictState

    /// The model version that produced this finding, when a model did.
    ///
    /// Pinned per inspection and recorded per finding, so a finding remains attributable
    /// after a model is rolled back. When a bad model version is revoked, the findings it
    /// produced can be identified and re-reviewed rather than silently corrected, which
    /// matters because these are evidentiary records.
    public private(set) var modelVersion: String?
    public private(set) var confidence: Confidence?

    public private(set) var sync: SyncMetadata

    public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
        case minor
        case moderate
        case major
        case severe

        private var rank: Int {
            switch self {
            case .minor: return 0
            case .moderate: return 1
            case .major: return 2
            case .severe: return 3
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// Whether this finding is waiting on a human decision.
    public enum ConflictState: Sendable, Equatable, Codable {
        case none
        /// Both values are retained until someone chooses. Nothing is discarded, and the
        /// inspection cannot be submitted while this is outstanding.
        case pending(fields: Set<String>)
        case resolved(fields: Set<String>, keptLocal: Bool)

        public var isPending: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    /// Field keys used for dirty tracking and for the per-field conflict policy.
    /// Kept as a closed set so the client, the server, and the conformance corpus cannot
    /// drift on what a field is called.
    public enum Field {
        public static let defectClass = "defect_class"
        public static let severity = "severity"
        public static let measurement = "measurement_value"
        public static let note = "note"
        public static let attachedMedia = "attached_media"

        /// Fields that are never resolved automatically.
        ///
        /// Silently choosing between two damage measurements creates financial and legal
        /// exposure, so the architecture is constrained by a product decision rather than
        /// the other way round.
        public static let requiringManualResolution: Set<String> = [measurement, defectClass, severity]
    }

    public init(
        id: FindingID,
        inspectionID: InspectionID,
        defectClass: String,
        clock: HybridLogicalClock
    ) {
        self.id = id
        self.inspectionID = inspectionID
        self.defectClass = defectClass
        self.severity = nil
        self.measurement = nil
        self.note = ""
        self.attachedMedia = []
        self.conflictState = .none
        self.modelVersion = nil
        self.confidence = nil
        self.sync = SyncMetadata(hlc: clock)
    }

    // MARK: - Mutations

    public mutating func setDefectClass(_ value: String, clock: HybridLogicalClock) {
        guard value != defectClass else { return }
        defectClass = value
        sync.markDirty([Field.defectClass], at: clock)
    }

    public mutating func setSeverity(_ value: Severity?, clock: HybridLogicalClock) {
        guard value != severity else { return }
        severity = value
        sync.markDirty([Field.severity], at: clock)
    }

    public mutating func setMeasurement(_ value: SiteMeasurement?, clock: HybridLogicalClock) {
        guard value != measurement else { return }
        measurement = value
        sync.markDirty([Field.measurement], at: clock)
    }

    public mutating func setNote(_ value: String, clock: HybridLogicalClock) {
        guard value != note else { return }
        note = value
        sync.markDirty([Field.note], at: clock)
    }

    public mutating func attachMedia(_ mediaID: MediaID, clock: HybridLogicalClock) {
        guard attachedMedia.contains(mediaID) == false else { return }
        attachedMedia.insert(mediaID)
        sync.markDirty([Field.attachedMedia], at: clock)
    }

    public mutating func detachMedia(_ mediaID: MediaID, clock: HybridLogicalClock) {
        guard attachedMedia.contains(mediaID) else { return }
        attachedMedia.remove(mediaID)
        sync.markDirty([Field.attachedMedia], at: clock)
    }

    /// Records a model-produced result.
    ///
    /// A detection below the abstention threshold is not recorded as an assertion. The
    /// class and confidence are kept for telemetry, and the fields the model would have
    /// filled are left for a person, because an unfounded claim in an evidentiary record
    /// costs more than a missing one.
    public mutating func applyDetection(
        defectClass value: String,
        confidence detectionConfidence: Confidence,
        modelVersion version: String,
        clock: HybridLogicalClock
    ) {
        modelVersion = version
        confidence = detectionConfidence
        guard detectionConfidence.meetsAbstentionThreshold else { return }
        setDefectClass(value, clock: clock)
    }

    /// Marks fields as conflicting. Neither value is discarded.
    public mutating func markConflicted(fields: Set<String>) {
        guard fields.isEmpty == false else { return }
        conflictState = .pending(fields: fields)
    }

    public mutating func resolveConflict(keptLocal: Bool, clock: HybridLogicalClock) {
        guard case .pending(let fields) = conflictState else { return }
        conflictState = .resolved(fields: fields, keptLocal: keptLocal)
        sync.markDirty(fields, at: clock)
    }
}
