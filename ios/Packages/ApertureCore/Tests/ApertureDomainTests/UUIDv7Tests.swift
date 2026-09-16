import Testing
import Foundation
@testable import ApertureDomain
import ApertureTestSupport

// Swift Testing rather than XCTest: as of 2026 it is the recommended framework for unit
// tests, and XCTest remains only for UI testing through XCUITest.

@Suite("UUIDv7 generation")
struct UUIDv7Tests {

    @Test("carries the version 7 nibble and the RFC 9562 variant bits")
    func versionAndVariantBits() {
        let clock = TestDateProvider()
        let random = SeededRandomSource(seed: 42)

        let identifier = UUIDv7.generate(at: clock.now, random: random)
        let bytes = UUIDv7.byteArray(of: identifier)

        #expect(bytes[6] >> 4 == 0x7)
        #expect(bytes[8] >> 6 == 0b10)
        #expect(UUIDv7.isVersion7(identifier))
    }

    @Test("round-trips the creation timestamp to millisecond resolution")
    func timestampRoundTrip() throws {
        let instant = Date(timeIntervalSince1970: 1_789_000_000.123)
        let identifier = UUIDv7.generate(at: instant, random: SeededRandomSource(seed: 7))

        let recovered = try #require(UUIDv7.timestamp(of: identifier))

        #expect(abs(recovered.timeIntervalSince(instant)) < 0.001)
    }

    @Test("sorts in creation order, which is what keeps index locality good")
    func lexicographicOrderFollowsCreationOrder() {
        let random = SeededRandomSource(seed: 99)
        let base = Date(timeIntervalSince1970: 1_789_000_000)

        let earlier = InspectionID(rawValue: UUIDv7.generate(at: base, random: random))
        let later = InspectionID(
            rawValue: UUIDv7.generate(at: base.addingTimeInterval(1), random: random)
        )

        #expect(earlier < later)
    }

    @Test("produces distinct values inside the same millisecond")
    func distinctWithinOneMillisecond() {
        let instant = Date(timeIntervalSince1970: 1_789_000_000)
        let random = SeededRandomSource(seed: 3)

        let generated = (0..<1000).map { _ in UUIDv7.generate(at: instant, random: random) }

        #expect(Set(generated).count == 1000)
    }

    @Test("is reproducible from a seed, so a failing generative case can be replayed")
    func reproducibleFromSeed() {
        let instant = Date(timeIntervalSince1970: 1_789_000_000)

        let first = UUIDv7.generate(at: instant, random: SeededRandomSource(seed: 12345))
        let second = UUIDv7.generate(at: instant, random: SeededRandomSource(seed: 12345))

        #expect(first == second)
    }

    @Test("clamps rather than overflowing beyond the 48-bit timestamp field")
    func clampsFarFutureInstants() {
        let farFuture = Date(timeIntervalSince1970: 1e15)

        let identifier = UUIDv7.generate(at: farFuture, random: SeededRandomSource(seed: 1))

        #expect(UUIDv7.isVersion7(identifier))
    }

    @Test("rejects a non-version-7 value when reading a timestamp")
    func rejectsVersion4Values() {
        #expect(UUIDv7.timestamp(of: UUID()) == nil)
    }
}

@Suite("Typed identifiers")
struct EntityIDTests {

    @Test("parses a wire representation and rejects malformed input")
    func parsing() {
        let uuid = UUID()

        #expect(InspectionID(string: uuid.uuidString)?.rawValue == uuid)
        #expect(InspectionID(string: "not-a-uuid") == nil)
    }

    @Test("exposes the embedded creation instant for generated identifiers")
    func createdAtIsPopulated() {
        let clock = TestDateProvider()
        let identifier = FindingID(generatedAt: clock.now, random: SeededRandomSource(seed: 5))

        #expect(identifier.createdAt != nil)
    }
}
