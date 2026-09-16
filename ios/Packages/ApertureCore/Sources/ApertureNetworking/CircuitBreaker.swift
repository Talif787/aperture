import Foundation
import Synchronization
import ApertureDomain

/// Stops a client hammering a backend that is already failing.
///
/// On a server this protects the service. On a field device it also protects the battery,
/// which is the reason it lives on the client at all: a queue of three hundred operations
/// retrying against a dead endpoint for an entire shift is a measurable drain, and the
/// user gets nothing for it.
///
/// Three states. Closed lets everything through. Open rejects immediately for a cooling
/// period, without touching the radio. Half-open admits exactly one probe: if it succeeds
/// the circuit closes, if it fails the cooling period restarts. Admitting one rather than
/// all is what stops a recovering backend from being knocked over by the fleet the moment
/// it comes back.
public final class CircuitBreaker: Sendable {
    public enum State: Equatable, Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    private struct Storage {
        var state: State
        var consecutiveFailures: Int
        var probeInFlight: Bool
    }

    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private let dateProvider: any DateProviding
    private let storage: Mutex<Storage>

    public init(
        failureThreshold: Int = 5,
        cooldown: TimeInterval = 30,
        dateProvider: any DateProviding
    ) {
        precondition(failureThreshold > 0, "at least one failure must be permitted before opening")
        precondition(cooldown > 0, "a cooling period is required")
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
        self.dateProvider = dateProvider
        self.storage = Mutex(Storage(state: .closed, consecutiveFailures: 0, probeInFlight: false))
    }

    public var state: State {
        storage.withLock { current in
            transitionIfCooled(&current)
            return current.state
        }
    }

    /// Whether a request may proceed right now.
    ///
    /// Has a side effect on purpose: in the half-open state it reserves the single probe
    /// slot. Splitting the check from the reservation would let several callers each
    /// believe they were the probe.
    public func allowsRequest() -> Bool {
        storage.withLock { current in
            transitionIfCooled(&current)
            switch current.state {
            case .closed:
                return true
            case .open:
                return false
            case .halfOpen:
                guard current.probeInFlight == false else { return false }
                current.probeInFlight = true
                return true
            }
        }
    }

    public func recordSuccess() {
        storage.withLock { current in
            current.consecutiveFailures = 0
            current.probeInFlight = false
            current.state = .closed
        }
    }

    public func recordFailure() {
        storage.withLock { current in
            current.probeInFlight = false
            current.consecutiveFailures += 1

            if case .halfOpen = current.state {
                // The probe failed, so the backend is still unwell. Restart the cooling
                // period rather than counting toward the threshold again.
                current.state = .open(until: dateProvider.now.addingTimeInterval(cooldown))
                return
            }

            if current.consecutiveFailures >= failureThreshold {
                current.state = .open(until: dateProvider.now.addingTimeInterval(cooldown))
            }
        }
    }

    /// Forces the circuit closed. Used when connectivity is restored, because a network
    /// change invalidates the evidence that opened it.
    public func reset() {
        storage.withLock { current in
            current.state = .closed
            current.consecutiveFailures = 0
            current.probeInFlight = false
        }
    }

    private func transitionIfCooled(_ current: inout Storage) {
        guard case .open(let until) = current.state else { return }
        if dateProvider.now >= until {
            current.state = .halfOpen
            current.probeInFlight = false
        }
    }
}
