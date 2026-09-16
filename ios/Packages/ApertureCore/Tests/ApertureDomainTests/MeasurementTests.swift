import Testing
import Foundation
@testable import ApertureDomain

@Suite("Measurement and confidence")
struct MeasurementTests {

    @Test("metric values pass through untouched")
    func metricIsTheBaseUnit() {
        let length = SiteMeasurement(magnitude: 2.5, dimension: .length, source: .lidar)

        let display = length.displayValue(in: .metric)

        #expect(display.magnitude == 2.5)
        #expect(display.unit == "m")
    }

    @Test("imperial conversion round-trips within floating point tolerance")
    func imperialRoundTrip() {
        let original = SiteMeasurement(magnitude: 3.7, dimension: .area, source: .lidar)

        let displayed = original.displayValue(in: .imperial)
        let rebuilt = SiteMeasurement.fromDisplayValue(
            displayed.magnitude, unit: .imperial, dimension: .area, source: .manual
        )

        #expect(abs(rebuilt.magnitude - original.magnitude) < 0.000_001)
    }

    @Test("area and length use different conversion factors")
    func areaIsNotConvertedAsLength() {
        let area = SiteMeasurement(magnitude: 1, dimension: .area, source: .lidar)
        let length = SiteMeasurement(magnitude: 1, dimension: .length, source: .lidar)

        // One square metre is about 10.76 square feet, not 3.28. Conflating the two is a
        // three-fold error in a number that ends up in a settlement.
        #expect(abs(area.displayValue(in: .imperial).magnitude - 10.763_910) < 0.001)
        #expect(abs(length.displayValue(in: .imperial).magnitude - 3.280_839) < 0.001)
    }

    @Test("sensor provenance is distinguishable from human entry")
    func provenanceIsRecorded() {
        #expect(SiteMeasurement(magnitude: 1, dimension: .length, source: .lidar).isSensorDerived)
        #expect(SiteMeasurement(magnitude: 1, dimension: .length, source: .manual).isSensorDerived == false)
    }

    @Test("confidence rejects values outside zero and one", arguments: [-0.1, 1.1, Double.nan, Double.infinity])
    func confidenceIsBounded(value: Double) {
        #expect(Confidence(value) == nil)
    }

    @Test("a low-confidence detection does not meet the abstention threshold")
    func abstention() throws {
        let low = try #require(Confidence(0.31))
        let high = try #require(Confidence(0.92))

        #expect(low.meetsAbstentionThreshold == false)
        #expect(high.meetsAbstentionThreshold)
    }

    @Test("a detection below the threshold records telemetry but asserts nothing")
    func lowConfidenceDetectionDoesNotClaim() throws {
        let clock = HybridLogicalClock(wallClockMilliseconds: 1, counter: 0, nodeID: "devA")
        var finding = Finding(
            id: FindingID(rawValue: UUID()),
            inspectionID: InspectionID(rawValue: UUID()),
            defectClass: "unknown",
            clock: clock
        )

        finding.applyDetection(
            defectClass: "hail_bruising",
            confidence: try #require(Confidence(0.22)),
            modelVersion: "detect-v4.2.1",
            clock: clock
        )

        // The class is left alone: an unfounded claim in an evidentiary record costs more
        // than a missing one. The confidence and model version are still recorded, because
        // they are the retraining signal.
        #expect(finding.defectClass == "unknown")
        #expect(finding.modelVersion == "detect-v4.2.1")
        #expect(finding.confidence?.value == 0.22)
    }

    @Test("a confident detection is applied")
    func confidentDetectionIsApplied() throws {
        let clock = HybridLogicalClock(wallClockMilliseconds: 1, counter: 0, nodeID: "devA")
        var finding = Finding(
            id: FindingID(rawValue: UUID()),
            inspectionID: InspectionID(rawValue: UUID()),
            defectClass: "unknown",
            clock: clock
        )

        finding.applyDetection(
            defectClass: "missing_shingle",
            confidence: try #require(Confidence(0.88)),
            modelVersion: "detect-v4.2.1",
            clock: clock
        )

        #expect(finding.defectClass == "missing_shingle")
        #expect(finding.sync.dirtyFields.contains(Finding.Field.defectClass))
    }

    @Test("measurement and classification fields always require manual resolution")
    func manualResolutionSet() {
        #expect(Finding.Field.requiringManualResolution.contains(Finding.Field.measurement))
        #expect(Finding.Field.requiringManualResolution.contains(Finding.Field.defectClass))
        #expect(Finding.Field.requiringManualResolution.contains(Finding.Field.severity))
        // Free text is mergeable; a number is not.
        #expect(Finding.Field.requiringManualResolution.contains(Finding.Field.note) == false)
    }

    @Test("severity orders by seriousness")
    func severityOrdering() {
        #expect(Finding.Severity.minor < Finding.Severity.moderate)
        #expect(Finding.Severity.moderate < Finding.Severity.major)
        #expect(Finding.Severity.major < Finding.Severity.severe)
    }
}
