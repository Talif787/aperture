import Foundation
import Synchronization
import ApertureDomain

/// A media writer that records what happened and can fail on demand.
///
/// The recorded step log is what makes the durability ordering assertable. A test that only
/// checks the final state cannot tell the difference between "persisted then acknowledged"
/// and "acknowledged then persisted", and that difference is the entire guarantee.
public final class RecordingMediaWriter: MediaWriting, Sendable {
    public enum Step: String, Sendable, Equatable {
        case checkedSpace
        case wrote
        case removed
    }

    private struct Storage {
        var steps: [Step] = []
        var stored: Set<String> = []
        var availableBytes: Int64
        var failWrite: (any Error)?
        var failRemove: (any Error)?
    }

    private let storage: Mutex<Storage>

    public init(availableBytes: Int64 = 50 * 1024 * 1024 * 1024) {
        self.storage = Mutex(Storage(availableBytes: availableBytes))
    }

    public var steps: [Step] { storage.withLock { $0.steps } }
    public var storedHashes: Set<String> { storage.withLock { $0.stored } }

    public func setAvailableBytes(_ bytes: Int64) {
        storage.withLock { $0.availableBytes = bytes }
    }

    public func failNextWrite(with error: any Error) {
        storage.withLock { $0.failWrite = error }
    }

    public func failRemoval(with error: any Error) {
        storage.withLock { $0.failRemove = error }
    }

    public func availableBytes() async throws -> Int64 {
        storage.withLock { current in
            current.steps.append(.checkedSpace)
            return current.availableBytes
        }
    }

    public func write(_ data: Data, kind: MediaAsset.Kind) async throws -> WrittenMedia {
        try storage.withLock { current in
            if let error = current.failWrite {
                current.failWrite = nil
                throw error
            }
            current.steps.append(.wrote)
            let hash = Self.hash(of: data)
            current.stored.insert(hash)
            return WrittenMedia(contentHash: hash, byteCount: Int64(data.count), kind: kind)
        }
    }

    public func remove(contentHash: String) async throws {
        try storage.withLock { current in
            if let error = current.failRemove {
                current.failRemove = nil
                throw error
            }
            current.steps.append(.removed)
            current.stored.remove(contentHash)
        }
    }

    /// A deterministic stand-in for SHA-256, sized to match.
    ///
    /// Not a digest and not claiming to be one: the production writer hashes for real. This
    /// only needs to be stable and 64 hexadecimal characters so the content-addressing
    /// behavior is exercised without pulling a crypto dependency into a test double.
    private static func hash(of data: Data) -> String {
        var accumulator: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            accumulator = (accumulator ^ UInt64(byte)) &* 0x1000_0000_01B3
        }
        let base = String(format: "%016lx", accumulator)
        return String(repeating: base, count: 4)
    }
}

/// Reports whatever conditions a test asks for.
public final class StubDeviceConditions: DeviceConditionProviding, Sendable {
    private let storage: Mutex<(thermal: ThermalState, lowPower: Bool)>

    public init(thermalState: ThermalState = .nominal, isLowPowerModeEnabled: Bool = false) {
        self.storage = Mutex((thermalState, isLowPowerModeEnabled))
    }

    public var thermalState: ThermalState { storage.withLock { $0.thermal } }
    public var isLowPowerModeEnabled: Bool { storage.withLock { $0.lowPower } }

    public func set(thermalState: ThermalState) {
        storage.withLock { $0.thermal = thermalState }
    }

    public func set(isLowPowerModeEnabled: Bool) {
        storage.withLock { $0.lowPower = isLowPowerModeEnabled }
    }
}

/// Template fixtures, shaped like a real roof inspection so the conditional rules have
/// something meaningful to branch on.
public enum TemplateFixtures {
    public static func roofInspection(id: TemplateID, version: Int = 1) -> InspectionTemplate {
        InspectionTemplate(
            id: id,
            version: version,
            name: "Residential roof, hail",
            fields: [
                TemplateField(
                    key: "roof_material",
                    label: "Roof material",
                    kind: .choice(["asphalt_shingle", "tile", "metal", "other"]),
                    requirement: .always
                ),
                // Only asked when the answer above was "other", which is the conditional
                // case the engine exists to handle.
                TemplateField(
                    key: "roof_material_other",
                    label: "Describe the material",
                    kind: .text(multiline: false),
                    visibility: .equals(field: "roof_material", value: .choice("other")),
                    requirement: .equals(field: "roof_material", value: .choice("other")),
                    validation: TemplateField.Validation(maximumLength: 120)
                ),
                TemplateField(
                    key: "slope_degrees",
                    label: "Slope",
                    kind: .number(unit: "degrees"),
                    requirement: .always,
                    validation: TemplateField.Validation(minimum: 0, maximum: 90)
                ),
                // A steep roof brings a safety question that a flat one does not.
                TemplateField(
                    key: "fall_protection_used",
                    label: "Fall protection used",
                    kind: .boolean,
                    visibility: .greaterThan(field: "slope_degrees", value: 30),
                    requirement: .greaterThan(field: "slope_degrees", value: 30)
                ),
                TemplateField(
                    key: "access_notes",
                    label: "Access notes",
                    kind: .text(multiline: true),
                    validation: TemplateField.Validation(maximumLength: 2000)
                )
            ],
            captureRequirements: [
                CaptureRequirement(key: "elevation_photos", label: "Elevations", kind: .photo, minimumCount: 4),
                CaptureRequirement(
                    key: "damage_closeups",
                    label: "Damage close-ups",
                    kind: .photo,
                    minimumCount: 2,
                    condition: .equals(field: "roof_material", value: .choice("asphalt_shingle"))
                )
            ]
        )
    }
}
