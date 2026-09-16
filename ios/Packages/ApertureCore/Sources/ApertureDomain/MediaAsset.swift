import Foundation

/// A captured photograph, video, or scan.
///
/// The identity of a media asset is its content hash, not its path. That single decision
/// makes deduplication, integrity verification, and post-crash reconciliation intrinsic
/// rather than bolted on: a file that exists is verifiable, a chunk that was already
/// uploaded is recognisable, and a retry is naturally idempotent because the destination
/// name is derived from the bytes.
public struct MediaAsset: Sendable, Equatable, Identifiable, Codable {
    public let id: MediaID
    public let inspectionID: InspectionID
    public let contentHash: String
    public let byteCount: Int64
    public let kind: Kind
    public let capturedAt: Date

    public private(set) var findingID: FindingID?
    public private(set) var uploadState: UploadState
    public private(set) var isRedacted: Bool
    public private(set) var sync: SyncMetadata

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case photo
        case video
        case roomScan
    }

    /// Where an asset is in its journey off the device.
    ///
    /// `localOnly` is the default and the common case: structured findings sync, media
    /// stays put unless tenant policy or an explicit consent says otherwise. At the
    /// projected Year 3 volume, uploading everything would be roughly 43 TB per day, so
    /// this is an economic constraint as much as a privacy one.
    public enum UploadState: String, Sendable, Codable, CaseIterable {
        case localOnly
        case uploading
        case uploaded
        case purged
    }

    public init(
        id: MediaID,
        inspectionID: InspectionID,
        contentHash: String,
        byteCount: Int64,
        kind: Kind,
        capturedAt: Date,
        clock: HybridLogicalClock
    ) {
        precondition(contentHash.count == 64, "a SHA-256 hash is 64 hexadecimal characters")
        precondition(byteCount > 0, "a captured asset has content")
        self.id = id
        self.inspectionID = inspectionID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.kind = kind
        self.capturedAt = capturedAt
        self.findingID = nil
        self.uploadState = .localOnly
        self.isRedacted = false
        self.sync = SyncMetadata(hlc: clock)
    }

    /// Whether the local file may be reclaimed.
    ///
    /// Only after the server has confirmed receipt. Purging on optimism is how an
    /// inspector loses the only copy of evidence from a site they will not revisit.
    public var isPurgeEligible: Bool {
        uploadState == .uploaded
    }

    public mutating func beginUpload(clock: HybridLogicalClock) {
        guard uploadState == .localOnly else { return }
        uploadState = .uploading
        sync.markDirty(["upload_state"], at: clock)
    }

    public mutating func confirmUploaded(clock: HybridLogicalClock) {
        uploadState = .uploaded
        sync.markDirty(["upload_state"], at: clock)
    }

    public mutating func markRedacted(clock: HybridLogicalClock) {
        guard isRedacted == false else { return }
        isRedacted = true
        sync.markDirty(["redacted"], at: clock)
    }

    public mutating func attach(to finding: FindingID, clock: HybridLogicalClock) {
        guard findingID != finding else { return }
        findingID = finding
        sync.markDirty(["finding_id"], at: clock)
    }
}
