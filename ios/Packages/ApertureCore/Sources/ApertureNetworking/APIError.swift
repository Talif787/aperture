import Foundation
import ApertureDomain

/// The uniform error envelope every non-2xx response carries.
///
/// The `message` field is deliberately absent from this type. The server sends one for
/// engineers and logs, and it must never reach a user: it is unlocalised, it can name
/// internal entities, and it changes without notice. The client maps `code` to a
/// localised string instead, which is why `code` is part of the support contract and is
/// not changed casually.
public struct APIError: Error, Equatable, Sendable, Decodable {
    public let code: String
    public let httpStatus: Int
    public let retryable: Bool
    public let correlationID: String?
    public let details: Details?

    public struct Details: Equatable, Sendable, Decodable {
        public let entityType: String?
        public let entityID: String?
        public let serverVersion: Int64?
        public let clientBaseVersion: Int64?
        public let conflictingFields: [String]?
        public let missingFields: [String]?
        public let minimumVersion: String?
        public let bytesNeeded: Int64?

        /// Written out rather than synthesized, and rather than relying on a decoder-wide
        /// snake-case strategy.
        ///
        /// Two reasons. A global strategy would silently reshape every other type the same
        /// decoder touches, and it would still get `entityID` wrong, since it produces
        /// `entityId`. More importantly, every field here is optional, so a key mismatch
        /// does not throw: it decodes successfully with nils, and the failure surfaces far
        /// downstream as a missing value nobody can explain. Explicit keys make the wire
        /// contract reviewable in one place.
        private enum CodingKeys: String, CodingKey {
            case entityType = "entity_type"
            case entityID = "entity_id"
            case serverVersion = "server_version"
            case clientBaseVersion = "client_base_version"
            case conflictingFields = "conflicting_fields"
            case missingFields = "missing_fields"
            case minimumVersion = "minimum_version"
            case bytesNeeded = "bytes_needed"
        }

        public init(
            entityType: String? = nil,
            entityID: String? = nil,
            serverVersion: Int64? = nil,
            clientBaseVersion: Int64? = nil,
            conflictingFields: [String]? = nil,
            missingFields: [String]? = nil,
            minimumVersion: String? = nil,
            bytesNeeded: Int64? = nil
        ) {
            self.entityType = entityType
            self.entityID = entityID
            self.serverVersion = serverVersion
            self.clientBaseVersion = clientBaseVersion
            self.conflictingFields = conflictingFields
            self.missingFields = missingFields
            self.minimumVersion = minimumVersion
            self.bytesNeeded = bytesNeeded
        }
    }

    public init(
        code: String,
        httpStatus: Int,
        retryable: Bool,
        correlationID: String? = nil,
        details: Details? = nil
    ) {
        self.code = code
        self.httpStatus = httpStatus
        self.retryable = retryable
        self.correlationID = correlationID
        self.details = details
    }

    private enum RootKeys: String, CodingKey { case error }
    private enum ErrorKeys: String, CodingKey {
        case code, httpStatus = "http_status", retryable, correlationID = "correlation_id", details
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let nested = try root.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
        code = try nested.decode(String.self, forKey: .code)
        httpStatus = try nested.decode(Int.self, forKey: .httpStatus)
        retryable = try nested.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        correlationID = try nested.decodeIfPresent(String.self, forKey: .correlationID)
        details = try nested.decodeIfPresent(Details.self, forKey: .details)
    }
}

/// Classification of an HTTP status into what the client should do about it.
public enum ResponseDisposition: Equatable, Sendable {
    case success
    /// Retry after the given delay, or after the policy's own backoff when nil.
    case retry(after: TimeInterval?)
    /// The request will never succeed as sent. Surface it or dead-letter it.
    case fail
    /// Concurrency was detected. Not a failure: it is the conflict resolution path.
    case conflict
    /// Authentication expired. One refresh, then one retry, then fail.
    case reauthenticate

    public static func forStatus(_ status: Int, retryAfter: TimeInterval? = nil) -> ResponseDisposition {
        switch status {
        case 200...299:
            return .success
        case 401:
            return .reauthenticate
        case 409:
            return .conflict
        case 408, 429:
            return .retry(after: retryAfter)
        case 500, 502, 503, 504:
            return .retry(after: retryAfter)
        default:
            // Everything else, including 400, 403, 404, 422 and 426, is permanent.
            // Retrying a validation failure or an authorization failure can never succeed,
            // and on a field device it spends battery on a guaranteed failure.
            return .fail
        }
    }
}

/// Translates transport and API failures into the domain's error vocabulary.
///
/// The boundary exists so that no layer above the data layer ever sees an HTTP status or
/// a URL error. A view model that switches on `404` is a view model that has to be
/// rewritten when the API changes.
public enum ErrorMapper {
    public static func domainError(from apiError: APIError) -> DomainError {
        switch apiError.code {
        case "CONFLICT_VERSION_MISMATCH":
            return .conflictRequiresResolution(
                entity: apiError.details?.entityType ?? "record",
                conflictingFields: apiError.details?.conflictingFields ?? []
            )
        case "ILLEGAL_STATE_TRANSITION":
            return .illegalStateTransition(from: "server", to: "requested")
        case "VALIDATION_FAILED":
            let fields = apiError.details?.missingFields ?? []
            return .validation(fields.map { FieldError(fieldKey: $0, reason: .required) })
        case "CLIENT_VERSION_UNSUPPORTED":
            return .clientVersionUnsupported(minimumVersion: apiError.details?.minimumVersion ?? "unknown")
        case "UNAUTHENTICATED", "TOKEN_EXPIRED":
            return .authenticationRequired
        case "FORBIDDEN", "NOT_FOUND":
            // Cross-tenant access returns 404 rather than 403 so the API never confirms
            // the existence of data the caller cannot see. Both map to the same
            // user-facing outcome for exactly that reason.
            return .notDownloaded(entity: apiError.details?.entityType ?? "record")
        default:
            return .unrecoverable(code: apiError.code, correlationID: apiError.correlationID ?? "none")
        }
    }

    public static func domainError(from transportError: TransportError, correlationID: String) -> DomainError {
        switch transportError {
        case .timedOut, .cannotConnect, .connectionLost, .dnsFailure, .cancelled:
            // Not surfaced to the user. Offline is a normal operating mode in this
            // product, and presenting it as an error is the fastest way to make a working
            // field tool feel broken.
            return .unrecoverable(code: "ERR-4601", correlationID: correlationID)
        case .tlsFailure:
            return .unrecoverable(code: "ERR-4802", correlationID: correlationID)
        case .unexpectedResponse:
            return .unrecoverable(code: "ERR-4802", correlationID: correlationID)
        }
    }
}
