import ApertureCapture
import ApertureDomain
import Foundation
import Testing

/// These exercise the durability ordering the product's central promise rests on.
///
/// They run against a real temporary directory rather than a mocked file system, because
/// the properties worth checking are atomicity and content addressing, and a mock would
/// simply agree with whatever the implementation does.
@Suite("File system media writer")
struct FileSystemMediaWriterTests {
    private func makeWriter() throws -> (FileSystemMediaWriter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-tests-\(UUID().uuidString)", isDirectory: true)
        return (try FileSystemMediaWriter(directory: directory), directory)
    }

    @Test("A written asset is addressed by the SHA-256 of its contents")
    func contentAddressing() async throws {
        let (writer, _) = try makeWriter()
        let data = Data("photo bytes".utf8)

        let written = try await writer.write(data, kind: .photo)

        // The hash is the asset's identity rather than an attribute of it, which is what
        // lets the server recognise a re-uploaded capture as the same evidence.
        #expect(written.contentHash.count == 64)
        #expect(written.byteCount == Int64(data.count))
        #expect(written.kind == .photo)
    }

    @Test("Writing identical bytes twice produces one file and one identity")
    func deduplication() async throws {
        let (writer, directory) = try makeWriter()
        let data = Data("the same capture".utf8)

        let first = try await writer.write(data, kind: .photo)
        let second = try await writer.write(data, kind: .photo)

        #expect(first == second)

        // A retry after an ambiguous failure must not produce a second asset the server
        // would treat as separate evidence of the same defect.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == 1)
    }

    @Test("Empty bytes are refused rather than written")
    func emptyIsRefused() async throws {
        let (writer, _) = try makeWriter()

        // Empty data means acquisition failed without reporting it. Writing it would record
        // an asset with no content and no way for anything downstream to notice.
        await #expect(throws: DomainError.self) {
            _ = try await writer.write(Data(), kind: .photo)
        }
    }

    @Test("Removing an asset that is already absent succeeds")
    func removeIsIdempotent() async throws {
        let (writer, _) = try makeWriter()

        // remove is called to roll back a transaction that failed. A rollback that throws
        // because there was nothing to roll back turns one failure into two.
        try await writer.remove(contentHash: String(repeating: "a", count: 64))
    }

    @Test("Removing a written asset deletes the file")
    func removeDeletes() async throws {
        let (writer, _) = try makeWriter()
        let written = try await writer.write(Data("to be removed".utf8), kind: .photo)

        let path = writer.url(for: written.contentHash).path
        #expect(FileManager.default.fileExists(atPath: path))

        try await writer.remove(contentHash: written.contentHash)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("No partial file is left behind under a temporary name")
    func noPartialsRemain() async throws {
        let (writer, directory) = try makeWriter()

        for index in 0..<10 {
            _ = try await writer.write(Data("capture \(index)".utf8), kind: .photo)
        }

        // A file still named "incoming-" means a write was interrupted between the
        // temporary write and the rename, and the rename is what makes the operation
        // atomic.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains { $0.hasPrefix("incoming-") })
        #expect(contents.count == 10)
    }

    @Test("Available capacity is reported")
    func capacity() async throws {
        let (writer, _) = try makeWriter()

        let available = try await writer.availableBytes()

        // Not asserting a threshold, which would fail on a full CI runner for reasons
        // unrelated to the code. The property is that a figure is obtainable at all, since
        // capture refuses before acquiring based on it.
        #expect(available > 0)
    }
}

@Suite("System device conditions")
struct SystemDeviceConditionsTests {
    @Test("Thermal state maps into the domain's vocabulary")
    func thermalMapping() {
        let conditions = SystemDeviceConditions()

        // The value depends on the machine, so the assertion is that it is one of the
        // known cases rather than a specific one. A test that demanded .nominal would fail
        // on a warm runner and teach people to rerun it.
        #expect(ThermalState.allCases.contains(conditions.thermalState))
    }

    @Test("Low power mode is readable")
    func lowPower() {
        let conditions = SystemDeviceConditions()
        _ = conditions.isLowPowerModeEnabled
    }
}
