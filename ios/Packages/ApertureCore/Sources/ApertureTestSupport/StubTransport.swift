import Foundation
import Synchronization
import ApertureNetworking

/// A transport that answers from a script.
///
/// Every network condition the client must survive is expressible here: a timeout, a
/// throttle with a `Retry-After`, a run of 5xx followed by success, a captive portal
/// answering 200 with HTML. Driving those through an injected transport rather than a
/// proxy keeps the tests deterministic and fast enough to run on every commit.
public final class StubTransport: HTTPTransport, Sendable {
    /// What the transport does for one call.
    public enum Outcome: Sendable {
        case respond(HTTPResponse)
        case fail(TransportError)
    }

    private struct Storage {
        var scripted: [Outcome]
        var recorded: [HTTPRequest]
        var fallback: Outcome
    }

    private let storage: Mutex<Storage>

    /// - Parameters:
    ///   - outcomes: consumed in order, one per call.
    ///   - fallback: used once the script is exhausted, so a test that under-specifies
    ///     fails on an assertion rather than on an index out of range.
    public init(
        outcomes: [Outcome] = [],
        fallback: Outcome = .respond(HTTPResponse(statusCode: 200))
    ) {
        self.storage = Mutex(Storage(scripted: outcomes, recorded: [], fallback: fallback))
    }

    /// Every request the client actually sent, in order.
    public var recordedRequests: [HTTPRequest] {
        storage.withLock { $0.recorded }
    }

    public var callCount: Int {
        storage.withLock { $0.recorded.count }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let outcome = storage.withLock { current -> Outcome in
            current.recorded.append(request)
            guard current.scripted.isEmpty == false else { return current.fallback }
            return current.scripted.removeFirst()
        }

        switch outcome {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }

    // MARK: - Common scripts

    /// A run of failures followed by a success, for exercising retry and backoff.
    public static func failing(
        times count: Int,
        with error: TransportError = .timedOut,
        thenStatus status: Int = 200
    ) -> StubTransport {
        StubTransport(
            outcomes: Array(repeating: .fail(error), count: count)
                + [.respond(HTTPResponse(statusCode: status))]
        )
    }

    /// A throttling response naming its own delay.
    public static func throttled(retryAfterSeconds seconds: Int, thenStatus status: Int = 200) -> StubTransport {
        StubTransport(outcomes: [
            .respond(HTTPResponse(statusCode: 429, headers: ["Retry-After": String(seconds)])),
            .respond(HTTPResponse(statusCode: status))
        ])
    }

    /// A captive portal: HTTP 200, HTML body, nothing to do with this API.
    ///
    /// The case worth testing explicitly, because the naive client parses the login page
    /// into a domain model and reports a corrupt server rather than absence of network.
    public static func captivePortal() -> StubTransport {
        let body = Data("<html><head><title>Sign in to continue</title></head></html>".utf8)
        return StubTransport(
            outcomes: [.respond(HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], body: body))],
            fallback: .respond(HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], body: body))
        )
    }
}

/// Collects the delays a client asked to wait for, without waiting.
///
/// A retry test that sleeps for real takes minutes and is skipped; one that records the
/// schedule takes microseconds and runs on every commit. Which of those happens decides
/// whether backoff is ever actually verified.
public final class RecordingSleeper: Sendable {
    private let recorded = Mutex([TimeInterval]())

    public init() {}

    public var delays: [TimeInterval] {
        recorded.withLock { $0 }
    }

    public var totalDelay: TimeInterval {
        recorded.withLock { $0.reduce(0, +) }
    }

    public func sleep(_ seconds: TimeInterval) async throws {
        recorded.withLock { $0.append(seconds) }
    }
}
