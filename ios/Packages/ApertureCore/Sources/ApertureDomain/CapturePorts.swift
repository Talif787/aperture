import Foundation

/// Writes captured bytes to durable storage.
///
/// Declared in the domain so the durable-write ordering can be tested without a camera, a
/// file system, or a device. That ordering is the product's central promise, and a promise
/// that can only be exercised on hardware is a promise nobody exercises.
public protocol MediaWriting: Sendable {
    /// Persists bytes and returns their content address.
    ///
    /// Must not return until the data is durable. The whole guarantee rests on this: if it
    /// returns before the bytes survive a power loss, every layer above is building on sand.
    func write(_ data: Data, kind: MediaAsset.Kind) async throws -> WrittenMedia

    /// Removes a previously written asset, for rollback when the transaction that should
    /// have recorded it fails.
    func remove(contentHash: String) async throws

    /// Free space, so capture can be refused before acquisition rather than after.
    func availableBytes() async throws -> Int64
}

/// The result of a durable write.
public struct WrittenMedia: Sendable, Equatable {
    /// SHA-256, lowercase hex. The asset's identity, not an attribute of it.
    public let contentHash: String
    public let byteCount: Int64
    public let kind: MediaAsset.Kind

    public init(contentHash: String, byteCount: Int64, kind: MediaAsset.Kind) {
        precondition(contentHash.count == 64, "a SHA-256 hash is 64 hexadecimal characters")
        precondition(byteCount > 0, "a captured asset has content")
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.kind = kind
    }
}

/// Thermal and power conditions, which degrade capture rather than stopping it.
public protocol DeviceConditionProviding: Sendable {
    var thermalState: ThermalState { get }
    var isLowPowerModeEnabled: Bool { get }
}

public enum ThermalState: String, Sendable, Equatable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Whether on-device inference should still run.
    ///
    /// Capture itself never stops for heat. Losing the evidence is worse than losing the
    /// analysis, and the analysis can be redone later from the media while the site cannot
    /// be revisited.
    public var permitsInference: Bool {
        self < .critical
    }

    /// Whether inference should run at reduced input resolution.
    public var requiresReducedResolution: Bool {
        self >= .serious
    }
}

/// Storage thresholds, as policy rather than as numbers scattered through the capture code.
public enum StoragePolicy {
    /// Below this, warn and begin evicting media the server has already confirmed.
    public static let warningThreshold: Int64 = 2 * 1024 * 1024 * 1024

    /// Below this, refuse to capture.
    ///
    /// Refused **before** acquisition, never after. A capture that is taken and then fails
    /// to persist is the one outcome the product must never produce, because the inspector
    /// saw a shutter fire and will believe the evidence exists.
    public static let blockingThreshold: Int64 = 500 * 1024 * 1024

    public static func disposition(availableBytes: Int64) -> Disposition {
        if availableBytes < blockingThreshold { return .blocked }
        if availableBytes < warningThreshold { return .warning }
        return .ample
    }

    public enum Disposition: Sendable, Equatable {
        case ample
        case warning
        case blocked
    }
}
