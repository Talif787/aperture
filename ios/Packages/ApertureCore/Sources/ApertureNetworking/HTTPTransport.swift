import Foundation
import ApertureDomain

/// The seam between the typed client and whatever actually performs the request.
///
/// Declared here, with no reference to URLSession, for two reasons. It keeps the retry
/// policy, the circuit breaker, and the error mapping testable on any machine with no
/// network and no simulator. And it makes fault injection a matter of substituting an
/// implementation rather than intercepting at the socket, which is how the offline and
/// network-failure matrices get exercised deterministically.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct HTTPRequest: Sendable, Equatable {
    public var method: Method
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?

    /// Present on every mutating request, absent on reads.
    ///
    /// On a marginal network every request outcome is one of three things: success,
    /// failure, or unknown. Unknown is the common case, and the idempotency key is what
    /// converts unknown into safely retryable.
    public var idempotencyKey: String?

    /// Generated on the device, per logical operation.
    ///
    /// The device generates it rather than the server, and the direction matters: it is
    /// what makes one field session traceable from the shutter press through to the
    /// database commit. A server-generated identifier can only ever describe the server's
    /// half of the story.
    public var correlationID: String

    public var timeout: TimeInterval

    public enum Method: String, Sendable, CaseIterable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"

        /// Whether the method is safe to replay without an idempotency key.
        public var isIdempotentByDefinition: Bool {
            self == .get || self == .put || self == .delete
        }
    }

    public init(
        method: Method,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        idempotencyKey: String? = nil,
        correlationID: String,
        timeout: TimeInterval = 15
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.correlationID = correlationID
        self.timeout = timeout
    }

    /// Whether replaying this request can be relied upon not to duplicate its effect.
    public var isSafeToRetry: Bool {
        method.isIdempotentByDefinition || idempotencyKey != nil
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Header lookup that does not depend on the casing a proxy happened to use.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// Seconds to wait, from a `Retry-After` header.
    ///
    /// Honoured exactly, never shortened. A client that treats throttling as a transient
    /// error to retry immediately turns a load problem into an outage.
    public var retryAfter: TimeInterval? {
        guard let raw = header("Retry-After"), let seconds = TimeInterval(raw) else { return nil }
        return seconds
    }
}

/// Failures below the HTTP layer: the request never produced a response.
public enum TransportError: Error, Equatable, Sendable {
    case timedOut
    case cannotConnect
    case connectionLost
    case tlsFailure
    case dnsFailure
    case cancelled
    /// A response arrived that is structurally not from this API.
    ///
    /// The usual cause is a captive portal answering every request with a login page, and
    /// treating it as a corrupt API response rather than as absence of connectivity is how
    /// a client ends up parsing HTML into a domain model. Every hotel and many job sites
    /// have one.
    case unexpectedResponse(statusCode: Int)

    /// Whether the request may be sent again as-is.
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .cannotConnect, .connectionLost, .dnsFailure:
            return true
        case .tlsFailure, .cancelled, .unexpectedResponse:
            // A TLS failure is either a genuine interception attempt or a misconfiguration
            // on our side. Retrying achieves nothing and hides the signal.
            return false
        }
    }

    /// Whether this failure should count toward opening the circuit breaker.
    public var indicatesServiceUnavailable: Bool {
        switch self {
        case .timedOut, .cannotConnect, .connectionLost, .dnsFailure:
            return true
        case .tlsFailure, .cancelled, .unexpectedResponse:
            return false
        }
    }
}
