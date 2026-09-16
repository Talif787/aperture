import Foundation
import os

/// The telemetry surface every other module depends on.
///
/// Redaction happens here, at the boundary, rather than at each call site. Relying on
/// every engineer to remember `privacy: .private` at every interpolation is a policy that
/// fails silently and exactly once, and the failure is customer imagery or form content
/// in a log file.
public protocol Telemetry: Sendable {
    func event(_ name: StaticString, attributes: [String: TelemetryValue])
    func error(_ code: String, correlationID: String?)
    func measurement(_ name: StaticString, milliseconds: Double)
}

/// Values permitted in telemetry attributes.
///
/// A closed set of non-identifying types, by construction. There is no `case string`
/// carrying arbitrary user text, so free-text notes, form values, addresses, and file
/// paths cannot be attached to an event even by accident.
public enum TelemetryValue: Sendable, Equatable {
    case count(Int)
    case duration(Double)
    case flag(Bool)
    /// A value drawn from a fixed, code-defined vocabulary, such as a device tier or a
    /// network class. Never user-supplied text.
    case category(StaticStringBacked)

    public struct StaticStringBacked: Sendable, Equatable {
        public let value: String
        public init(_ literal: StaticString) {
            self.value = literal.description
        }
    }
}

/// Production implementation over the unified logging system.
public struct OSLogTelemetry: Telemetry {
    private let logger: Logger
    private let signposter: OSSignposter

    public init(subsystem: String = "com.aperture", category: String = "telemetry") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    public func event(_ name: StaticString, attributes: [String: TelemetryValue]) {
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

/// Discards everything. Used in unit tests and in previews so that neither writes to the
/// log stream or to an analytics buffer.
public struct NoOpTelemetry: Telemetry {
    public init() {}
    public func event(_ name: StaticString, attributes: [String: TelemetryValue]) {}
    public func error(_ code: String, correlationID: String?) {}
    public func measurement(_ name: StaticString, milliseconds: Double) {}
}
