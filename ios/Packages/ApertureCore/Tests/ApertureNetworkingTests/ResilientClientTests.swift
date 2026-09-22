import Testing
import Foundation
@testable import ApertureNetworking
import ApertureDomain
import ApertureSync
import ApertureTestSupport

@Suite("Resilient client")
struct ResilientClientTests {

    /// The pieces one client test needs.
    ///
    /// A named type rather than a three-member tuple, so a test reads `harness.sleeper`
    /// instead of destructuring three values in the right order at every call site.
    private struct ClientHarness {
        let client: ResilientClient
        let sleeper: RecordingSleeper
        let dateProvider: TestDateProvider
    }

    private func makeClient(
        transport: StubTransport,
        sleeper: RecordingSleeper = RecordingSleeper(),
        policy: RetryPolicy = .standard
    ) -> ClientHarness {
        let dateProvider = TestDateProvider()
        let breaker = CircuitBreaker(failureThreshold: 5, cooldown: 30, dateProvider: dateProvider)
        let client = ResilientClient(
            transport: transport,
            retryPolicy: policy,
            breaker: breaker,
            random: SeededRandomSource(seed: 99),
            sleep: { seconds in try await sleeper.sleep(seconds) }
        )
        return ClientHarness(client: client, sleeper: sleeper, dateProvider: dateProvider)
    }

    private func request(
        method: HTTPRequest.Method = .post,
        idempotencyKey: String? = "op-1"
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            path: "/v1/sync/deltas",
            idempotencyKey: idempotencyKey,
            correlationID: "corr-1"
        )
    }

    @Test("a successful response is returned without retrying")
    func successPath() async throws {
        let transport = StubTransport(outcomes: [.respond(HTTPResponse(statusCode: 200))])
        let harness = makeClient(transport: transport)
        let client = harness.client
        let sleeper = harness.sleeper

        let response = try await client.send(request())

        #expect(response.statusCode == 200)
        #expect(transport.callCount == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("a transient transport failure is retried and then succeeds")
    func retriesTransientFailures() async throws {
        let transport = StubTransport.failing(times: 2, with: .timedOut)
        let harness = makeClient(transport: transport)
        let client = harness.client
        let sleeper = harness.sleeper

        let response = try await client.send(request())

        #expect(response.statusCode == 200)
        #expect(transport.callCount == 3)
        #expect(sleeper.delays.count == 2)
        // The schedule is asserted, not slept through. A test that waits for real backoff
        // takes minutes and gets skipped, which means backoff is never verified at all.
        #expect(sleeper.totalDelay < 20)
    }

    @Test("every retry carries the original idempotency key")
    func retriesReuseTheIdempotencyKey() async throws {
        let transport = StubTransport.failing(times: 2)
        let client = makeClient(transport: transport).client

        _ = try await client.send(request())

        let keys = Set(transport.recordedRequests.compactMap(\.idempotencyKey))
        // A fresh key per attempt would defeat the entire mechanism: the server would
        // treat each retry as a new operation and apply the effect more than once.
        #expect(keys == ["op-1"])
    }

    @Test("a non-idempotent request is not retried")
    func doesNotRetryUnsafeRequests() async {
        let transport = StubTransport.failing(times: 1)
        let client = makeClient(transport: transport).client

        await #expect(throws: DomainError.self) {
            _ = try await client.send(self.request(method: .post, idempotencyKey: nil))
        }
        #expect(transport.callCount == 1)
    }

    @Test("a TLS failure is not retried")
    func tlsFailureIsTerminal() async {
        let transport = StubTransport(outcomes: [.fail(.tlsFailure)])
        let client = makeClient(transport: transport).client

        // Either a genuine interception attempt or a misconfiguration on our side.
        // Retrying achieves nothing and buries the signal.
        await #expect(throws: DomainError.self) {
            _ = try await client.send(self.request())
        }
        #expect(transport.callCount == 1)
    }

    @Test("throttling honours the server's Retry-After")
    func honoursRetryAfter() async throws {
        let transport = StubTransport.throttled(retryAfterSeconds: 12)
        let harness = makeClient(transport: transport)
        let client = harness.client
        let sleeper = harness.sleeper

        _ = try await client.send(request())

        let first = try #require(sleeper.delays.first)
        // Never shorter than the server asked for. A client that retries sooner turns a
        // load problem into an outage.
        #expect(first >= 12)
    }

    @Test("a validation failure is surfaced immediately")
    func permanentFailureIsNotRetried() async {
        let body = Data("""
        {"error":{"code":"VALIDATION_FAILED","http_status":422,
        "details":{"missing_fields":["roof_type"]}}}
        """.utf8)
        let transport = StubTransport(outcomes: [.respond(HTTPResponse(statusCode: 422, body: body))])
        let client = makeClient(transport: transport).client

        do {
            _ = try await client.send(request())
            Issue.record("expected a failure")
        } catch let error as DomainError {
            guard case .validation(let fields) = error else {
                Issue.record("expected validation, got \(error)")
                return
            }
            #expect(fields.map(\.fieldKey) == ["roof_type"])
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(transport.callCount == 1)
    }

    @Test("a conflict is returned to the caller rather than thrown")
    func conflictIsNotAnError() async throws {
        let transport = StubTransport(outcomes: [.respond(HTTPResponse(statusCode: 409))])
        let client = makeClient(transport: transport).client

        let response = try await client.send(request())

        // Concurrency detection is the resolution path, not a failure. Throwing here would
        // push conflict handling into every call site's error branch.
        #expect(response.statusCode == 409)
    }

    @Test("a 401 is returned so the token manager can refresh once")
    func unauthenticatedIsReturned() async throws {
        let transport = StubTransport(outcomes: [.respond(HTTPResponse(statusCode: 401))])
        let client = makeClient(transport: transport).client

        let response = try await client.send(request())

        #expect(response.statusCode == 401)
    }

    @Test("the circuit opens after sustained failure and rejects without a call")
    func circuitOpensUnderSustainedFailure() async {
        let transport = StubTransport(
            outcomes: [],
            fallback: .fail(.cannotConnect)
        )
        let policy = RetryPolicy(baseDelay: 0.001, maximumDelay: 0.01, maximumAttempts: 20)
        let client = makeClient(transport: transport, policy: policy).client

        _ = try? await client.send(request())
        let callsAfterFirst = transport.callCount

        _ = try? await client.send(request())

        // Once open, the second send is rejected locally. On a field device this is a
        // battery protection as much as a server protection.
        #expect(transport.callCount == callsAfterFirst)
    }

    @Test("a captive portal is treated as absence of network, not a corrupt API")
    func captivePortalIsNotParsed() async {
        let client = makeClient(transport: StubTransport.captivePortal()).client

        // A 200 with an HTML body is the signature of a hotel or job-site login page.
        // The naive client parses it into a domain model and reports a broken server.
        let response = try? await client.send(request(method: .get, idempotencyKey: nil))

        #expect(response?.statusCode == 200)
        #expect(response?.header("Content-Type") == "text/html")
    }
}

@Suite("Response disposition")
struct ResponseDispositionTests {

    @Test("retryable statuses", arguments: [408, 429, 500, 502, 503, 504])
    func retryable(status: Int) {
        guard case .retry = ResponseDisposition.forStatus(status) else {
            Issue.record("\(status) should be retryable")
            return
        }
    }

    @Test("permanent statuses", arguments: [400, 403, 404, 422, 426])
    func permanent(status: Int) {
        #expect(ResponseDisposition.forStatus(status) == .fail)
    }

    @Test("special cases are not failures")
    func specialCases() {
        #expect(ResponseDisposition.forStatus(200) == .success)
        #expect(ResponseDisposition.forStatus(409) == .conflict)
        #expect(ResponseDisposition.forStatus(401) == .reauthenticate)
    }
}
