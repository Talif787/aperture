import Foundation
import os
import ApertureDomain

/// The production `Telemetry` implementation, over the unified logging system.
///
/// The protocol itself lives in `ApertureDomain`, so the domain and the sync engine can
/// emit events without depending on an Apple framework, which is what keeps them
/// buildable and testable on any machine.
///
/// Redaction happens here, at the boundary, rather than at each call site. Relying on
/// every engineer to remember a privacy specifier at every interpolation is a policy that
/// fails silently and exactly once, and the failure is customer content in a log
/// aggregator.
public struct OSLogTelemetry: Telemetry {
    private let logger: Logger

    public init(subsystem: String = "com.aperture", category: String = "telemetry") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func event(_ name: StaticString, attributes: [String: TelemetryValue]) {
        // StaticString is converted at the boundary: the unified logging interpolation has
        // no overload accepting a privacy specifier on StaticString, and the event name is
        // always a compile-time literal, so marking it public is correct.
        logger.info("event=\(name.description, privacy: .public) attrs=\(describe(attributes), privacy: .public)")
    }

    public func error(_ code: String, correlationID: String?) {
        logger.error(
            "error code=\(code, privacy: .public) correlation=\(correlationID ?? "none", privacy: .public)"
        )
    }

    public func measurement(_ name: StaticString, milliseconds: Double) {
        logger.info("measure=\(name.description, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    private func describe(_ attributes: [String: TelemetryValue]) -> String {
        attributes
            .sorted { $0.key < $1.key }
            .map { key, value in
                switch value {
                case .count(let count): return "\(key)=\(count)"
                case .duration(let seconds): return "\(key)=\(seconds)"
                case .flag(let flag): return "\(key)=\(flag)"
                case .category(let category): return "\(key)=\(category.value)"
                }
            }
            .joined(separator: " ")
    }
}
