import Foundation

/// Captures one media asset and records it durably.
///
/// The ordering in `execute` is the product's central durability guarantee, and it is the
/// reason this use case exists as a separate, testable unit rather than as code inside a
/// view model.
///
/// The bytes are written and made durable, then the database record and the sync operation
/// are committed together, and only then does the caller learn it succeeded. An interface
/// that acknowledges first and persists afterwards turns every crash, every jetsam, and
/// every battery death into silent data loss, and the inspector has no way to know: they
/// saw the shutter fire.
///
/// The transaction covering the record and the operation together matters just as much. A
/// crash between them leaves an asset the user can see and the server will never hear about,
/// which is the same loss wearing a different hat.
public struct CaptureMedia: Sendable {
    private let mediaWriter: any MediaWriting
    private let media: any MediaRepository
    private let operations: any SyncOperationSink
    private let transactions: any TransactionRunner
    private let clock: HybridLogicalClockGenerator
    private let dateProvider: any DateProviding
    private let random: any RandomSource
    private let telemetry: any Telemetry

    public init(
        mediaWriter: any MediaWriting,
        media: any MediaRepository,
        operations: any SyncOperationSink,
        transactions: any TransactionRunner,
        clock: HybridLogicalClockGenerator,
        dateProvider: any DateProviding,
        random: any RandomSource,
        telemetry: any Telemetry = NoOpTelemetry()
    ) {
        self.mediaWriter = mediaWriter
        self.media = media
        self.operations = operations
        self.transactions = transactions
        self.clock = clock
        self.dateProvider = dateProvider
        self.random = random
        self.telemetry = telemetry
    }

    public struct Request: Sendable {
        public let inspectionID: InspectionID
        public let data: Data
        public let kind: MediaAsset.Kind
        public let findingID: FindingID?

        public init(
            inspectionID: InspectionID,
            data: Data,
            kind: MediaAsset.Kind,
            findingID: FindingID? = nil
        ) {
            self.inspectionID = inspectionID
            self.data = data
            self.kind = kind
            self.findingID = findingID
        }
    }

    public func execute(_ request: Request) async throws -> MediaAsset {
        // 1. Refuse before acquiring, never after. A capture that fires and then fails to
        //    persist is the one outcome that must not happen, because the inspector saw the
        //    shutter and will believe the evidence exists.
        try await refuseIfStorageExhausted()

        // 2. Durable write. Returns only once the bytes survive a power loss.
        let written = try await mediaWriter.write(request.data, kind: request.kind)

        let asset = MediaAsset(
            id: MediaID(generatedAt: dateProvider.now, random: random),
            inspectionID: request.inspectionID,
            contentHash: written.contentHash,
            byteCount: written.byteCount,
            kind: written.kind,
            capturedAt: dateProvider.now,
            clock: clock.send()
        )

        // 3. Record and enqueue atomically. Either both land or neither does.
        try await recordOrReclaim(asset, request: request, written: written)

        telemetry.event("capture.completed", attributes: [
            "bytes": .count(Int(written.byteCount)),
            "kind": .category(TelemetryCategory("media"))
        ])

        // 4. Only now may the caller tell the user it worked.
        return asset
    }

    private func refuseIfStorageExhausted() async throws {
        let available = try await mediaWriter.availableBytes()
        guard StoragePolicy.disposition(availableBytes: available) == .blocked else { return }

        telemetry.error("ERR-4301", correlationID: nil)
        throw DomainError.storageFull(
            bytesNeeded: StoragePolicy.blockingThreshold - available
        )
    }

    /// Commits the record and the sync operation together, reclaiming the bytes on failure.
    ///
    /// The transaction covering both matters as much as the durable write itself. A crash
    /// between them leaves an asset the user can see and the server will never hear about,
    /// which is the same loss wearing a different hat.
    private func recordOrReclaim(
        _ asset: MediaAsset,
        request: Request,
        written: WrittenMedia
    ) async throws {
        do {
            try await transactions.inTransaction {
                var stored = asset
                if let findingID = request.findingID {
                    stored.attach(to: findingID, clock: clock.send())
                }
                try await media.save(stored)
                try await operations.enqueue(pendingOperation(for: stored))
            }
        } catch {
            // The bytes are on disk with nothing pointing at them. Reclaiming immediately
            // keeps the common case tidy, and the launch reconciliation pass collects
            // anything this misses, because a content-addressed file with no record is
            // recognisable as an orphan without needing a log of what went wrong.
            try? await mediaWriter.remove(contentHash: written.contentHash)
            telemetry.error("ERR-4801", correlationID: nil)
            throw error
        }
    }

    private func pendingOperation(for asset: MediaAsset) -> PendingOperation {
        PendingOperation(
            id: OperationID(generatedAt: dateProvider.now, random: random),
            entityType: "media_asset",
            entityID: asset.id.description,
            kind: "attach_media",
            dirtyFields: ["content_hash", "upload_state"],
            baseVersion: 0,
            hlc: asset.sync.hlc,
            createdAt: dateProvider.now
        )
    }
}
