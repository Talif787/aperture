import Foundation

/// A typed identifier for a domain entity.
///
/// Primitive obsession is how a tenant identifier ends up passed where an inspection
/// identifier was expected, which the compiler cannot catch when both are `String`.
/// The phantom type parameter makes that a build error at no runtime cost.
public struct EntityID<Subject>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Mints a new creation-ordered identifier.
    public init(generatedAt instant: Date, random: some RandomSource) {
        self.rawValue = UUIDv7.generate(at: instant, random: random)
    }

    /// Parses a wire representation, returning `nil` when the string is not a UUID.
    public init?(string: String) {
        guard let parsed = UUID(uuidString: string) else { return nil }
        self.rawValue = parsed
    }

    public var description: String { rawValue.uuidString }

    /// The embedded creation instant, present for version 7 identifiers.
    public var createdAt: Date? { UUIDv7.timestamp(of: rawValue) }
}

extension EntityID: Comparable {
    /// Orders by the raw byte sequence, which for version 7 values is creation order.
    public static func < (lhs: EntityID<Subject>, rhs: EntityID<Subject>) -> Bool {
        UUIDv7.byteArray(of: lhs.rawValue)
            .lexicographicallyPrecedes(UUIDv7.byteArray(of: rhs.rawValue))
    }
}

public enum InspectionSubject: Sendable {}
public enum FindingSubject: Sendable {}
public enum MediaSubject: Sendable {}
public enum TenantSubject: Sendable {}
public enum DeviceSubject: Sendable {}
public enum OperationSubject: Sendable {}

public typealias InspectionID = EntityID<InspectionSubject>
public typealias FindingID = EntityID<FindingSubject>
public typealias MediaID = EntityID<MediaSubject>
public typealias TenantID = EntityID<TenantSubject>
public typealias DeviceID = EntityID<DeviceSubject>
public typealias OperationID = EntityID<OperationSubject>
