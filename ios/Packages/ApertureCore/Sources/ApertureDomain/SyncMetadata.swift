import Foundation

/// The synchronization state every syncable entity carries.
///
/// Two fields here are load-bearing in ways their size does not suggest.
///
/// `dirtyFields` is a set rather than a boolean. With a single flag the server cannot tell
/// which fields the client actually changed, so any concurrent edit forces a whole-entity
/// choice, and that clobbers a reviewer's edit to a field the inspector never touched.
/// Field-level tracking is what makes automatic merging safe in the common case and
/// manual resolution rare.
///
/// `baseVersion` records the server version an edit was derived from. Comparing it against
/// the server's current version is how concurrency is detected at all. Without it the
/// server can only offer last-writer-wins, which for measurement values is unacceptable.
public struct SyncMetadata: Sendable, Equatable, Codable {
    /// Assigned by the server. Zero means this entity has never been acknowledged.
    public private(set) var serverVersion: Int64

    /// The server version this entity's local edits were derived from.
    public private(set) var baseVersion: Int64

    /// Causal stamp of the most recent mutation.
    public private(set) var hlc: HybridLogicalClock

    /// Field keys modified locally since the last acknowledgment.
    public private(set) var dirtyFields: Set<String>

    /// Tombstone marker. Deletion is soft, because a delete must propagate to replicas
    /// that are currently in a crawl space with no signal.
    public private(set) var deletedAt: Date?

    /// When the server last confirmed this entity. Displayed to the user, because the
    /// difference between "there is nothing" and "I have not heard recently" matters to
    /// someone deciding whether to act on what is on screen.
    public private(set) var lastSyncedAt: Date?

    public init(hlc: HybridLogicalClock) {
        self.serverVersion = 0
        self.baseVersion = 0
        self.hlc = hlc
        self.dirtyFields = []
        self.deletedAt = nil
        self.lastSyncedAt = nil
    }

    /// True when this entity has local changes the server has not seen.
    public var hasPendingChanges: Bool {
        dirtyFields.isEmpty == false || (deletedAt != nil && serverVersion == 0)
    }

    /// True when the device is authoritative for this entity.
    ///
    /// The distinction drives caching: an entity the user has modified is never evicted
    /// or overwritten by a server read, while one they have only viewed is a cache entry
    /// that can expire, because it is re-fetchable.
    public var isLocallyAuthoritative: Bool {
        hasPendingChanges
    }

    public var isDeleted: Bool {
        deletedAt != nil
    }

    /// Records a local mutation to the named fields.
    public mutating func markDirty(_ fields: Set<String>, at clock: HybridLogicalClock) {
        dirtyFields.formUnion(fields)
        hlc = clock
    }

    /// Records a soft delete.
    public mutating func markDeleted(at instant: Date, clock: HybridLogicalClock) {
        deletedAt = instant
        hlc = clock
    }

    /// Applies a server acknowledgment, clearing the fields the server accepted.
    ///
    /// Only the acknowledged fields are cleared. Anything the user changed while the
    /// request was in flight stays dirty, which is the behavior that keeps an edit made
    /// during a slow sync from being silently dropped.
    public mutating func acknowledge(
        serverVersion newVersion: Int64,
        acceptedFields: Set<String>,
        at instant: Date
    ) {
        serverVersion = newVersion
        baseVersion = newVersion
        dirtyFields.subtract(acceptedFields)
        lastSyncedAt = instant
    }

    /// Adopts server state wholesale, for an entity with no local modifications.
    public mutating func adoptServerState(
        serverVersion newVersion: Int64,
        clock: HybridLogicalClock,
        at instant: Date
    ) {
        serverVersion = newVersion
        baseVersion = newVersion
        hlc = clock
        lastSyncedAt = instant
    }
}
