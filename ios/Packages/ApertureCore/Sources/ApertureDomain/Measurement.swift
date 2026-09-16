import Foundation

/// A physical quantity recorded during an inspection, with its provenance.
///
/// Stored in SI base units and converted only for display. A unit mismatch in an insurance
/// report is a financial and legal exposure, not a formatting bug, so conversion happens
/// in exactly one place rather than at each call site.
public struct SiteMeasurement: Sendable, Equatable, Codable {
    /// The value, always in the SI base unit for its dimension: metres, or square metres.
    public let magnitude: Double
    public let dimension: Dimension
    public let source: Source

    /// Absolute accuracy band, in the same base unit, when the source can report one.
    ///
    /// Present so the interface can show uncertainty rather than assert a number. A depth
    /// measurement taken at the edge of tracking quality is not the same claim as one
    /// taken against a clean surface, and flattening the two is how a reviewer ends up
    /// defending a figure nobody should have trusted.
    public let accuracy: Double?

    public enum Dimension: String, Sendable, Codable, CaseIterable {
        case length
        case area
    }

    /// How the value was obtained. Recorded because it determines how much weight the
    /// value can carry, and because a model-derived number must be attributable to the
    /// model version that produced it.
    public enum Source: String, Sendable, Codable, CaseIterable {
        case lidar
        case referenceObject
        case manual
        case ocr
    }

    public init(magnitude: Double, dimension: Dimension, source: Source, accuracy: Double? = nil) {
        precondition(magnitude.isFinite, "a measurement must be a finite value")
        precondition(magnitude >= 0, "a physical extent cannot be negative")
        self.magnitude = magnitude
        self.dimension = dimension
        self.source = source
        self.accuracy = accuracy
    }

    /// True when the value came from a sensor rather than a person.
    public var isSensorDerived: Bool {
        source == .lidar || source == .referenceObject
    }

    // MARK: - Display conversion

    public enum UnitSystem: String, Sendable, Codable {
        case metric
        case imperial
    }

    private static let feetPerMetre = 3.280_839_895_013_123
    private static let squareFeetPerSquareMetre = 10.763_910_416_709_722

    /// The value expressed in the requested system, with the unit symbol to render.
    public func displayValue(in system: UnitSystem) -> (magnitude: Double, unit: String) {
        switch (dimension, system) {
        case (.length, .metric):
            return (magnitude, "m")
        case (.length, .imperial):
            return (magnitude * Self.feetPerMetre, "ft")
        case (.area, .metric):
            return (magnitude, "m\u{00B2}")
        case (.area, .imperial):
            return (magnitude * Self.squareFeetPerSquareMetre, "ft\u{00B2}")
        }
    }

    /// Builds a measurement from a value a user typed in their own unit system.
    public static func fromDisplayValue(
        _ value: Double,
        unit system: UnitSystem,
        dimension: Dimension,
        source: Source
    ) -> SiteMeasurement {
        let magnitude: Double
        switch (dimension, system) {
        case (.length, .metric), (.area, .metric):
            magnitude = value
        case (.length, .imperial):
            magnitude = value / feetPerMetre
        case (.area, .imperial):
            magnitude = value / squareFeetPerSquareMetre
        }
        return SiteMeasurement(magnitude: magnitude, dimension: dimension, source: source)
    }
}

/// A calibrated model confidence in the closed interval zero to one.
///
/// A distinct type rather than a bare `Double` so that a probability cannot be passed
/// where a measurement was expected, and so the abstention threshold lives with the value
/// it governs.
public struct Confidence: Sendable, Equatable, Comparable, Codable {
    public let value: Double

    public init?(_ value: Double) {
        guard value.isFinite, value >= 0, value <= 1 else { return nil }
        self.value = value
    }

    /// Constructs without validating, for compile-time constants that are provably in
    /// range. Private, so the only way to build one from runtime data remains the
    /// failable initializer.
    private init(unvalidated value: Double) {
        self.value = value
    }

    /// Below this, the system asserts nothing and asks the user instead.
    ///
    /// Stating a low-confidence detection as fact is worse than staying silent: it costs
    /// the inspector time to correct and, if uncorrected, puts an unfounded claim into an
    /// evidentiary record.
    public static let abstentionThreshold = Confidence(unvalidated: 0.55)

    public var meetsAbstentionThreshold: Bool {
        self >= Self.abstentionThreshold
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.value < rhs.value
    }
}
