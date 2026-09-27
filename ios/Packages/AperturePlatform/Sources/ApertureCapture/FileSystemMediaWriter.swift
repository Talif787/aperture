import ApertureDomain
import CryptoKit
import Foundation

/// Writes captured media to the container's Application Support directory.
///
/// The whole product rests on the ordering this type implements: bytes are durable before
/// the caller is told they exist. Everything above assumes it, and nothing above can check
/// it, so the guarantee has to be complete here or not at all.
public actor FileSystemMediaWriter: MediaWriting {
    private let directory: URL
    private let fileManager: FileManager

    /// - Parameter directory: where assets live. Defaults to Application Support, which is
    ///   excluded from iCloud backup by policy below and is not purged under disk pressure
    ///   the way Caches is. Evidence in a purgeable directory is evidence the system may
    ///   delete while the inspector is still driving to the next site.
    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        if let directory {
            self.directory = directory
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = base.appendingPathComponent("Media", isDirectory: true)
        }

        try Self.prepare(self.directory, fileManager: fileManager)
    }

    private static func prepare(_ directory: URL, fileManager: FileManager) throws {
        var target = directory

        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        // Excluded from backup deliberately. These files are large, they are already
        // destined for the server, and restoring a device should not drag a gigabyte of
        // someone else's inspection photos onto it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)

        // Protected until first unlock rather than complete. Complete protection would make
        // the files unreadable while the device is locked, and a background upload that
        // starts while the phone is in a pocket is exactly the case this must support.
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: target.path
        )
    }

    public func write(_ data: Data, kind: MediaAsset.Kind) async throws -> WrittenMedia {
        guard !data.isEmpty else {
            // Empty bytes mean acquisition failed without reporting it, which is worse
            // than a thrown error because the caller would record an asset that has no
            // content and no way to notice.
            throw DomainError.unrecoverable(code: "ERR-4802", correlationID: "capture.empty")
        }

        let digest = SHA256.hash(data: data)
        let contentHash = digest.map { String(format: "%02x", $0) }.joined()
        let destination = url(for: contentHash)

        // Content addressed, so an identical capture written twice is one file. That is not
        // an optimization: a retry after an ambiguous failure must not produce a second
        // asset the server will treat as a separate piece of evidence.
        if fileManager.fileExists(atPath: destination.path) {
            return WrittenMedia(
                contentHash: contentHash,
                byteCount: Int64(data.count),
                kind: kind
            )
        }

        // Written to a temporary name and renamed. A rename within one volume is atomic, so
        // a crash mid-write leaves a partial temporary file rather than a truncated asset
        // under a hash that claims to describe its whole contents.
        let temporary = directory.appendingPathComponent(
            "incoming-\(UUID().uuidString)",
            isDirectory: false
        )

        do {
            // .atomic writes to a temporary of its own and renames; the additional rename
            // below is what places it at its content address.
            try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)

            // Reported as storage pressure when that is what it is, because the caller can
            // act on that: it evicts confirmed media and retries. Anything else is
            // unrecoverable from capture's point of view.
            if (error as NSError).code == NSFileWriteOutOfSpaceError {
                throw DomainError.storageFull(bytesNeeded: Int64(data.count))
            }
            throw DomainError.unrecoverable(code: "ERR-4803", correlationID: "capture.write")
        }

        return WrittenMedia(contentHash: contentHash, byteCount: Int64(data.count), kind: kind)
    }

    public func remove(contentHash: String) async throws {
        let target = url(for: contentHash)

        guard fileManager.fileExists(atPath: target.path) else {
            // Already absent is success. This is called to roll back a transaction that
            // failed, and a rollback that throws because there was nothing to roll back
            // turns one failure into two.
            return
        }

        try fileManager.removeItem(at: target)
    }

    public func availableBytes() async throws -> Int64 {
        let values = try directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )

        // "Important usage" rather than plain available capacity. The plain figure counts
        // space the system would have to reclaim by purging caches, which it will not
        // necessarily do in time for a capture that is happening now.
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw DomainError.unrecoverable(code: "ERR-4804", correlationID: "capture.capacity")
        }

        return Int64(available)
    }

    /// The on-disk location of an asset. Exported so upload can read what capture wrote.
    public nonisolated func url(for contentHash: String) -> URL {
        directory.appendingPathComponent(contentHash, isDirectory: false)
    }
}
