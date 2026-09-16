import Foundation
import ApertureDomain
import ApertureNetworking

/// The production transport.
///
/// Thin on purpose. Everything about *when* to send lives in `ResilientClient`, where it
/// is testable without a network. This type does one thing: turn a typed request into a
/// URL request, perform it, and translate platform failures into `TransportError`.
///
/// One session, reused. A session per request is a connection-churn antipattern that
/// defeats HTTP/2 multiplexing and TLS session reuse, both of which matter a great deal on
/// a marginal cellular link.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let baseURL: URL

    public init(baseURL: URL, configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL
        // Two distinct timeouts. The request timeout is aggressive, because a stalled
        // request on a bad link should fail fast into the queue rather than hold a slot.
        // The resource timeout is generous, because a large media upload legitimately
        // takes a long time.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip"]
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try buildURLRequest(from: request)

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let http = response as? HTTPURLResponse else {
                throw TransportError.unexpectedResponse(statusCode: 0)
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headers[name] = text
                }
            }

            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let urlError as URLError {
            throw Self.transportError(from: urlError)
        }
    }

    private func buildURLRequest(from request: HTTPRequest) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw TransportError.unexpectedResponse(statusCode: 0)
        }

        if request.query.isEmpty == false {
            components.queryItems = request.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw TransportError.unexpectedResponse(statusCode: 0)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout

        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(request.correlationID, forHTTPHeaderField: "X-Correlation-Id")
        if let key = request.idempotencyKey {
            urlRequest.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }

        return urlRequest
    }

    /// Maps platform failures onto the transport vocabulary.
    ///
    /// The distinctions matter because they drive different behavior: a timeout is
    /// retryable and a TLS failure is not, and conflating them either hides an
    /// interception attempt or wastes battery retrying something that cannot succeed.
    static func transportError(from urlError: URLError) -> TransportError {
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost where urlError.code == .cannotConnectToHost:
            return .cannotConnect
        case .networkConnectionLost:
            return .connectionLost
        case .dnsLookupFailed:
            return .dnsFailure
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .tlsFailure
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet:
            return .cannotConnect
        default:
            return .cannotConnect
        }
    }
}
