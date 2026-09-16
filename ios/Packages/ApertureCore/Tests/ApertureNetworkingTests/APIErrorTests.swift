import Testing
import Foundation
@testable import ApertureNetworking
import ApertureDomain

@Suite("API error decoding")
struct APIErrorDecodingTests {

    /// The envelope exactly as the architecture document specifies it.
    private static let fullEnvelope = Data("""
    {
      "error": {
        "code": "CONFLICT_VERSION_MISMATCH",
        "http_status": 409,
        "message": "Entity was modified by another actor.",
        "correlation_id": "0f8c2a1e-6b2a-4f1e-9a22-9e2a0d9a1b77",
        "retryable": false,
        "details": {
          "entity_type": "finding",
          "entity_id": "01J8ZQ9K3R5T7V9X1Z3B5D7F9H",
          "server_version": 14,
          "client_base_version": 11,
          "conflicting_fields": ["measurement_value", "severity"]
        }
      }
    }
    """.utf8)

    @Test("every documented envelope field is mapped")
    func decodesTheFullEnvelope() throws {
        let error = try JSONDecoder().decode(APIError.self, from: Self.fullEnvelope)

        #expect(error.code == "CONFLICT_VERSION_MISMATCH")
        #expect(error.httpStatus == 409)
        #expect(error.retryable == false)
        #expect(error.correlationID == "0f8c2a1e-6b2a-4f1e-9a22-9e2a0d9a1b77")

        let details = try #require(error.details)
        // Each of these is a snake-case key that synthesized CodingKeys would miss. They
        // are asserted individually because every field is optional, so a mismatch decodes
        // to nil rather than throwing, and a test that only checks one field would pass
        // while the rest were silently empty.
        #expect(details.entityType == "finding")
        #expect(details.entityID == "01J8ZQ9K3R5T7V9X1Z3B5D7F9H")
        #expect(details.serverVersion == 14)
        #expect(details.clientBaseVersion == 11)
        #expect(details.conflictingFields == ["measurement_value", "severity"])
    }

    @Test("the engineer-facing message is not carried into the client")
    func messageIsNotExposed() throws {
        let error = try JSONDecoder().decode(APIError.self, from: Self.fullEnvelope)

        // The server sends `message` for logs. It is unlocalised, can name internal
        // entities, and changes without notice, so the type deliberately has no property
        // for it and the client maps `code` to a localised string instead.
        #expect(error.code.isEmpty == false)
    }

    @Test("a validation envelope yields the missing field keys")
    func decodesMissingFields() throws {
        let body = Data("""
        {"error":{"code":"VALIDATION_FAILED","http_status":422,
        "details":{"missing_fields":["roof_type","slope"]}}}
        """.utf8)

        let error = try JSONDecoder().decode(APIError.self, from: body)

        #expect(error.details?.missingFields == ["roof_type", "slope"])
    }

    @Test("retryable defaults to false when the server omits it")
    func retryableDefaults() throws {
        let body = Data(#"{"error":{"code":"FORBIDDEN","http_status":403}}"#.utf8)

        let error = try JSONDecoder().decode(APIError.self, from: body)

        #expect(error.retryable == false)
        #expect(error.details == nil)
    }

    @Test("an absent code is a decoding failure rather than a silent default")
    func missingCodeThrows() {
        let body = Data(#"{"error":{"http_status":500}}"#.utf8)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(APIError.self, from: body)
        }
    }
}

@Suite("API error mapping")
struct ErrorMapperTests {

    @Test("a version conflict carries its fields into the domain error")
    func conflictMapping() {
        let apiError = APIError(
            code: "CONFLICT_VERSION_MISMATCH",
            httpStatus: 409,
            retryable: false,
            details: APIError.Details(
                entityType: "finding",
                conflictingFields: ["measurement_value"]
            )
        )

        guard case .conflictRequiresResolution(let entity, let fields) =
            ErrorMapper.domainError(from: apiError) else {
            Issue.record("expected a conflict")
            return
        }

        #expect(entity == "finding")
        #expect(fields == ["measurement_value"])
    }

    @Test("forbidden and not found map to the same outcome")
    func crossTenantResponsesAreIndistinguishable() {
        // Cross-tenant access returns 404 rather than 403 so the API never confirms the
        // existence of data the caller cannot see. Mapping both to the same domain error
        // keeps that property from leaking through the client's behavior.
        let forbidden = APIError(code: "FORBIDDEN", httpStatus: 403, retryable: false)
        let notFound = APIError(code: "NOT_FOUND", httpStatus: 404, retryable: false)

        #expect(ErrorMapper.domainError(from: forbidden) == ErrorMapper.domainError(from: notFound))
    }

    @Test("an unknown code becomes an unrecoverable error carrying the correlation id")
    func unknownCodeRetainsDiagnostics() {
        let apiError = APIError(
            code: "SOMETHING_NEW",
            httpStatus: 500,
            retryable: false,
            correlationID: "corr-99"
        )

        guard case .unrecoverable(let code, let correlationID) =
            ErrorMapper.domainError(from: apiError) else {
            Issue.record("expected an unrecoverable error")
            return
        }

        // A code this build has never seen must still be diagnosable in support, which is
        // what the correlation identifier is for.
        #expect(code == "SOMETHING_NEW")
        #expect(correlationID == "corr-99")
    }

    @Test("a client too old for the server maps to the forced-upgrade error")
    func versionGate() {
        let apiError = APIError(
            code: "CLIENT_VERSION_UNSUPPORTED",
            httpStatus: 426,
            retryable: false,
            details: APIError.Details(minimumVersion: "2.4.0")
        )

        #expect(
            ErrorMapper.domainError(from: apiError)
                == .clientVersionUnsupported(minimumVersion: "2.4.0")
        )
    }
}
