import Foundation

/// Generation and inspection of version 7 UUIDs (RFC 9562).
///
/// Every syncable entity in Aperture receives its final identifier on the device at the
/// moment of creation. That single decision removes the identifier-mapping problem from
/// the whole offline system: there are no temporary identifiers to reconcile, and a child
/// operation never has to wait for its parent to receive a server-assigned identifier.
///
/// Version 7 rather than version 4 because the leading 48 bits are a millisecond
/// timestamp, so identifiers sort in creation order. That keeps database index locality
/// good despite the values looking random, and it gives the sync queue a natural
/// tie-breaking order.
///
/// Layout, most significant byte first:
///
///     bytes 0-5   48-bit big-endian Unix timestamp in milliseconds
///     byte  6     high nibble 0x7 (version), low nibble random
///     byte  7     random
///     byte  8     high two bits 0b10 (variant), low six bits random
///     bytes 9-15  random
public enum UUIDv7 {
    /// Milliseconds representable in the 48-bit timestamp field. Exhausted in the year 10889.
    static let maximumTimestampMilliseconds: UInt64 = (1 << 48) - 1

    /// Generates a version 7 UUID for the supplied instant.
    public static func generate(at instant: Date, random: some RandomSource) -> UUID {
        let milliseconds = timestampMilliseconds(from: instant)
        let entropy = random.bytes(count: 10)
        return assemble(milliseconds: milliseconds, entropy: entropy)
    }

    /// Extracts the embedded creation instant, or `nil` if the value is not version 7.
    public static func timestamp(of uuid: UUID) -> Date? {
        let bytes = byteArray(of: uuid)
        guard bytes[6] >> 4 == 0x7 else { return nil }
        var milliseconds: UInt64 = 0
        for index in 0..<6 {
            milliseconds = (milliseconds << 8) | UInt64(bytes[index])
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// Reports whether the value carries the version 7 and RFC 9562 variant bits.
    public static func isVersion7(_ uuid: UUID) -> Bool {
        let bytes = byteArray(of: uuid)
        return bytes[6] >> 4 == 0x7 && bytes[8] >> 6 == 0b10
    }

    static func timestampMilliseconds(from instant: Date) -> UInt64 {
        let interval = instant.timeIntervalSince1970
        guard interval > 0 else { return 0 }
        let milliseconds = UInt64(interval * 1000)
        return min(milliseconds, maximumTimestampMilliseconds)
    }

    static func assemble(milliseconds: UInt64, entropy: [UInt8]) -> UUID {
        precondition(entropy.count >= 10, "version 7 generation requires 10 random bytes")
        var bytes = [UInt8](repeating: 0, count: 16)

        bytes[0] = UInt8((milliseconds >> 40) & 0xFF)
        bytes[1] = UInt8((milliseconds >> 32) & 0xFF)
        bytes[2] = UInt8((milliseconds >> 24) & 0xFF)
        bytes[3] = UInt8((milliseconds >> 16) & 0xFF)
        bytes[4] = UInt8((milliseconds >> 8) & 0xFF)
        bytes[5] = UInt8(milliseconds & 0xFF)

        bytes[6] = 0x70 | (entropy[0] & 0x0F)
        bytes[7] = entropy[1]
        bytes[8] = 0x80 | (entropy[2] & 0x3F)
        for index in 9..<16 {
            bytes[index] = entropy[index - 6]
        }

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func byteArray(of uuid: UUID) -> [UInt8] {
        let raw = uuid.uuid
        return [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15
        ]
    }
}
