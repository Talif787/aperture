import Testing
@testable import ApertureDomain

@Suite("Domain error classification")
struct DomainErrorTests {

    @Test("never retries an error that cannot succeed on a second attempt")
    func nonRetryableCases() {
        let cases: [DomainError] = [
            .validation([FieldError(fieldKey: "roof_pitch", reason: .required)]),
            .conflictRequiresResolution(entity: "finding", conflictingFields: ["measurement_value"]),
            .illegalStateTransition(from: "approved", to: "draft"),
            .storageFull(bytesNeeded: 500_000_000),
            .permissionDenied(permission: "camera"),
            .offlineGraceExpired,
            .measurementUnreliable,
            .clientVersionUnsupported(minimumVersion: "2.4.0")
        ]

        for error in cases {
            #expect(error.isRetryable == false, "\(error.code) must not be retried")
        }
    }

    @Test("every case carries a stable support code")
    func codesArePresent() {
        let cases: [DomainError] = [
            .validation([]),
            .conflictRequiresResolution(entity: "finding", conflictingFields: []),
            .illegalStateTransition(from: "a", to: "b"),
            .storageFull(bytesNeeded: 1),
            .permissionDenied(permission: "camera"),
            .deviceCapabilityUnavailable(capability: "lidar"),
            .authenticationRequired,
            .offlineGraceExpired,
            .notDownloaded(entity: "inspection"),
            .modelUnavailable(reason: "load failed"),
            .measurementUnreliable,
            .clientVersionUnsupported(minimumVersion: "2.4.0"),
            .unrecoverable(code: "ERR-9000", correlationID: "abc")
        ]

        for error in cases {
            #expect(error.code.isEmpty == false)
            #expect(error.code.hasPrefix("ERR-"))
        }
    }

    @Test("errors the user cannot act on are not presented")
    func nonActionableCasesAreLoggedNotShown() {
        #expect(DomainError.illegalStateTransition(from: "a", to: "b").isUserActionable == false)
        #expect(DomainError.unrecoverable(code: "ERR-9000", correlationID: "x").isUserActionable == false)
        #expect(DomainError.storageFull(bytesNeeded: 1).isUserActionable)
    }
}
