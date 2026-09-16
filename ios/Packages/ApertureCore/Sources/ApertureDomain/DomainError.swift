import Foundation

/// A field-level validation failure, carrying the template field it belongs to so the
/// presentation layer can move focus without pattern matching on message text.
public struct FieldError: Equatable, Sendable {
    public let fieldKey: String
    public let reason: Reason

    public enum Reason: Equatable, Sendable {
        case required
        case outOfRange(minimum: Double?, maximum: Double?)
        case malformed
        case unsupportedValue
    }

    public init(fieldKey: String, reason: Reason) {
        self.fieldKey = fieldKey
        self.reason = reason
    }
}

/// Everything a use case is permitted to throw.
///
/// Transport and API errors are mapped into this type at the repository boundary, so no
/// layer above the data layer ever sees an HTTP status code or a `URLError`. Each case
/// maps to exactly one localized string and one recovery action, and that mapping lives
/// in a single file so an unhandled case is a compile error rather than a fallback string
/// discovered in production.
public enum DomainError: Error, Equatable, Sendable {
    case validation([FieldError])
    case conflictRequiresResolution(entity: String, conflictingFields: [String])
    case illegalStateTransition(from: String, to: String)
    case storageFull(bytesNeeded: Int64)
    case permissionDenied(permission: String)
    case deviceCapabilityUnavailable(capability: String)
    case authenticationRequired
    case offlineGraceExpired
    case notDownloaded(entity: String)
    case modelUnavailable(reason: String)
    case measurementUnreliable
    case clientVersionUnsupported(minimumVersion: String)
    case unrecoverable(code: String, correlationID: String)

    /// Whether the operation that produced this error may be retried unchanged.
    ///
    /// Deliberately conservative: retrying a validation or authorization failure can never
    /// succeed, and on a field device it spends battery on a guaranteed failure.
    public var isRetryable: Bool {
        switch self {
        case .validation, .conflictRequiresResolution, .illegalStateTransition,
             .storageFull, .permissionDenied, .deviceCapabilityUnavailable,
             .offlineGraceExpired, .measurementUnreliable, .clientVersionUnsupported:
            return false
        case .authenticationRequired, .notDownloaded, .modelUnavailable, .unrecoverable:
            return true
        }
    }

    /// Whether the user can take an action that resolves this error.
    /// Errors that are not actionable are logged rather than presented.
    public var isUserActionable: Bool {
        switch self {
        case .validation, .conflictRequiresResolution, .storageFull, .permissionDenied,
             .authenticationRequired, .offlineGraceExpired, .clientVersionUnsupported,
             .measurementUnreliable:
            return true
        case .illegalStateTransition, .deviceCapabilityUnavailable, .notDownloaded,
             .modelUnavailable, .unrecoverable:
            return false
        }
    }

    /// Stable machine-readable code used in telemetry and support diagnostics.
    /// These strings are part of the support contract and are not changed casually.
    public var code: String {
        switch self {
        case .validation: return "ERR-4001"
        case .notDownloaded: return "ERR-4102"
        case .storageFull: return "ERR-4301"
        case .permissionDenied: return "ERR-4303"
        case .measurementUnreliable: return "ERR-4306"
        case .modelUnavailable: return "ERR-4401"
        case .conflictRequiresResolution: return "ERR-4501"
        case .illegalStateTransition: return "ERR-4502"
        case .offlineGraceExpired: return "ERR-4701"
        case .authenticationRequired: return "ERR-4702"
        case .deviceCapabilityUnavailable: return "ERR-4902"
        case .clientVersionUnsupported: return "ERR-4901"
        case .unrecoverable(let code, _): return code
        }
    }
}
