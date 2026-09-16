import Foundation

/// A source of wall-clock time that can be controlled in tests.
///
/// Named `DateProviding` rather than `Clock` deliberately: the Swift standard library
/// already defines `Clock`, and shadowing it produces confusing diagnostics at every
/// call site that also uses structured concurrency.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}
