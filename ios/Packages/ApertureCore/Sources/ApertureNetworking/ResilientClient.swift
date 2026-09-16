import Foundation
import ApertureDomain
import ApertureSync

/// Wraps a transport with the retry, backoff, and circuit-breaking policy.
///
/// Composed rather than inherited: the transport does one thing, and everything about
/// *when* to call it lives here, where it can be tested against a stub in microseconds
/// instead of against a network in seconds.
public struct ResilientClient: Sendable {
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let breaker: CircuitBreaker
    private let random: any RandomSource
    private let telemetry: any Telemetry

    /// Waits for a computed delay. Injected so tests advance a schedule rather than sleep.
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy = .standard,
        breaker: CircuitBreaker,
        random: any RandomSource,
        telemetry: any Telemetry = NoOpTelemetry(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.breaker = breaker
        self.random = random
        self.telemetry = telemetry
        self.sleep = sleep
    }

    /// Sends a request, retrying according to the policy.
    ///
    /// - Throws: `DomainError` only. Transport and HTTP concerns are mapped at this
    ///   boundary so no caller above the data layer has to know they exist.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard breaker.allowsRequest() else {
            telemetry.event("net.circuit_open", attributes: [:])
            throw DomainError.unrecoverable(code: "ERR-4604", correlationID: request.correlationID)
        }

        var attemptCount = 0

        while true {
            switch await performAttempt(request, attemptCount: attemptCount) {
            case .completed(let response):
                return response
            case .failed(let error):
                throw error
            case .retry(let delay):
                try await sleep(delay)
                attemptCount += 1
            }
        }
    }

    /// What one round trip produced, and what the loop should do next.
    private enum AttemptOutcome {
        case completed(HTTPResponse)
        case failed(DomainError)
        case retry(after: TimeInterval)
    }

    private func performAttempt(_ request: HTTPRequest, attemptCount: Int) async -> AttemptOutcome {
        do {
            let response = try await transport.send(request)
            return classify(response, request: request, attemptCount: attemptCount)
        } catch let transportError as TransportError {
            return classify(transportError, request: request, attemptCount: attemptCount)
        } catch {
            return .failed(.unrecoverable(code: "ERR-4802", correlationID: request.correlationID))
        }
    }

    private func classify(
        _ response: HTTPResponse,
        request: HTTPRequest,
        attemptCount: Int
    ) -> AttemptOutcome {
        switch ResponseDisposition.forStatus(response.statusCode, retryAfter: response.retryAfter) {
        case .success, .conflict, .reauthenticate:
            // A conflict is the resolution path and a 401 is the token manager's job.
            // Neither is a transport failure, so neither counts against the breaker, and
            // both are handed back rather than thrown: throwing would push conflict
            // handling into every call site's error branch.
            breaker.recordSuccess()
            return .completed(response)

        case .fail:
            breaker.recordSuccess()
            return .failed(decodeAPIError(from: response, correlationID: request.correlationID))

        case .retry(let serverDelay):
            breaker.recordFailure()
            guard canRetry(request, attemptCount: attemptCount) else {
                return .failed(decodeAPIError(from: response, correlationID: request.correlationID))
            }
            return .retry(after: delay(serverSupplied: serverDelay, attemptCount: attemptCount))
        }
    }

    private func classify(
        _ error: TransportError,
        request: HTTPRequest,
        attemptCount: Int
    ) -> AttemptOutcome {
        if error.indicatesServiceUnavailable {
            breaker.recordFailure()
        }

        guard error.isRetryable, canRetry(request, attemptCount: attemptCount) else {
            return .failed(ErrorMapper.domainError(from: error, correlationID: request.correlationID))
        }

        return .retry(after: retryPolicy.delay(forAttempt: attemptCount, random: random))
    }

    /// Whether a replay is both permitted by the policy and safe to perform.
    ///
    /// Without an idempotency key a replay could duplicate the effect, so failing is the
    /// safe outcome. The operation stays queued and is re-driven with its original key.
    private func canRetry(_ request: HTTPRequest, attemptCount: Int) -> Bool {
        request.isSafeToRetry && retryPolicy.shouldRetry(afterAttemptCount: attemptCount + 1)
    }

    /// A server-supplied `Retry-After` is honoured exactly, with jitter added on top
    /// rather than subtracted from it, so the fleet does not return in lockstep at the
    /// instant the server named.
    private func delay(serverSupplied: TimeInterval?, attemptCount: Int) -> TimeInterval {
        guard let serverSupplied else {
            return retryPolicy.delay(forAttempt: attemptCount, random: random)
        }
        return serverSupplied + retryPolicy.delay(forAttempt: 0, random: random)
    }

    private func decodeAPIError(from response: HTTPResponse, correlationID: String) -> DomainError {
        guard let apiError = try? JSONDecoder().decode(APIError.self, from: response.body) else {
            // A non-2xx with an unparseable body means something between the client and
            // the service answered, and it was not the service. Treated as a transport
            // anomaly rather than an API error, because parsing it further would be
            // inventing structure that is not there.
            return ErrorMapper.domainError(
                from: .unexpectedResponse(statusCode: response.statusCode),
                correlationID: correlationID
            )
        }
        return ErrorMapper.domainError(from: apiError)
    }
}
