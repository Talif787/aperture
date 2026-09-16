import Foundation

/// The protocol version this client build speaks.
///
/// Sync payloads are schema-strict, and a deployed field device may run an old build for
/// months. Versioning is therefore explicit and additive-only within a major: fields may
/// be added at any time, and removal, renaming, type narrowing, or a change in meaning
/// requires a new major that runs concurrently with the previous one for at least twelve
/// months.
///
/// This file is hand-written. Everything else in this target is generated from
/// `contracts/` by `scripts/generate.sh` into a `Generated/` subdirectory that is not
/// committed.
public enum ContractVersion {
    /// Path segment used by every REST and RPC endpoint.
    public static let major = "v1"

    /// Monotonic schema revision within the major version, sent as a header so the server
    /// can record which client schema a request came from and measure residual use of
    /// deprecated fields before removing them.
    public static let schemaRevision = 1

    /// Header names that carry cross-cutting request context.
    public enum Header {
        public static let correlationID = "X-Correlation-Id"
        public static let idempotencyKey = "Idempotency-Key"
        public static let client = "X-Aperture-Client"
        public static let deviceID = "X-Aperture-Device-Id"
        public static let schemaRevision = "X-Aperture-Schema-Revision"
    }
}
