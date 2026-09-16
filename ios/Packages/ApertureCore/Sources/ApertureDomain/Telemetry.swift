import Foundation

/// The telemetry surface every layer depends on.
///
/// Declared in the domain, implemented per platform. The sync engine and the domain need
/// to emit events, and neither can depend on a platform logging framework without losing
/// the property that makes them testable on any machine.
///
/// Redaction is a property of the implementation, applied at the boundary. Relying on
/// every engineer to remember it at every call site is a policy that fails silently and
/// exactly once, and the failure is customer content in a log aggregator.
public protocol Telemetry: Sendable {
    func event(_ name: StaticString, attributes: [String: TelemetryValue])
    func error(_ code: String, correlationID: String?)
    func measurement(_ name: StaticString, milliseconds: Double)
}

/// Values permitted in telemetry attributes.
///
/// A closed set of non-identifying types, by construction. There is no case carrying
/// arbitrary user text, so free-text notes, form values, addresses, and file paths cannot
/// be attached to an event even by accident.
public enum TelemetryValue: Sendable, Equatable {
    case count(Int)
    case duration(Double)
    case flag(Bool)
    /// A value from a fixed, code-defined vocabulary, such as a device tier or a network
    /// class. Never user-supplied text.
    case category(TelemetryCategory)
}

public struct TelemetryCategory: Sendable, Equatable {
    public let value: String

    public init(_ literal: StaticString) {
        self.value = literal.description
    }
}

/// Discards everything. Used in tests and previews so neither writes to a log stream or
/// an analytics buffer.
public struct NoOpTelemetry: Telemetry {
    public init() {}
    public func event(_ name: StaticString, attributes: [String: TelemetryValue]) {}
    public func error(_ code: String, correlationID: String?) {}
    public func measurement(_ name: StaticString, milliseconds: Double) {}
}
