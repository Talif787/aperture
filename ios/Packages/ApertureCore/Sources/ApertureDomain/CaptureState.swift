import Foundation

/// The capture surface's state machine.
///
/// Modeled explicitly rather than as a handful of booleans on a view model. Capture has a
/// genuinely awkward lifecycle: a session that must be configured before it can run,
/// hardware that can be taken away mid-shot by an incoming call, and thermal pressure that
/// degrades it without stopping it. Three booleans make several illegal states
/// representable, and in a long-lived flow every representable illegal state eventually
/// happens on someone's phone.
public enum CaptureState: Sendable, Equatable {
    /// No session. Nothing is holding the camera, which matters because a running session
    /// is among the most expensive things in the application.
    case idle

    /// Session being built. Cannot capture yet.
    case configuring

    /// Ready to capture.
    case ready

    /// Acquiring a frame.
    case capturing

    /// Frame acquired, being written and hashed. The user has not been told it succeeded
    /// yet, because it has not succeeded yet.
    case persisting

    /// Hardware taken by something else: a call, another app, a disconnected accessory.
    /// Recoverable without rebuilding the session.
    case interrupted(reason: InterruptionReason)

    /// Still usable, but reduced. Inference deferred, resolution lowered.
    case degraded(reason: DegradationReason)

    /// Not usable until the user acts.
    case failed(DomainError)

    public enum InterruptionReason: String, Sendable, Equatable {
        case incomingCall
        case anotherApplication
        case hardwareDisconnected
        case backgrounded
    }

    public enum DegradationReason: String, Sendable, Equatable {
        case thermalPressure
        case lowPowerMode
        case storagePressure
    }

    /// Whether the shutter should do anything.
    public var acceptsCapture: Bool {
        switch self {
        case .ready, .degraded:
            return true
        case .idle, .configuring, .capturing, .persisting, .interrupted, .failed:
            return false
        }
    }

    /// Whether the camera session should be running.
    ///
    /// Drives teardown. A session left running while the user reads a form is a measurable
    /// drain for no benefit, and the AR session is worse.
    public var requiresActiveSession: Bool {
        switch self {
        case .ready, .capturing, .persisting, .degraded:
            return true
        case .idle, .configuring, .interrupted, .failed:
            return false
        }
    }

    public var isTerminal: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Events the state machine responds to.
public enum CaptureEvent: Sendable, Equatable {
    case configure
    case configured
    case shutterPressed
    case frameAcquired
    case persisted
    case interrupted(CaptureState.InterruptionReason)
    case interruptionEnded
    case degradationBegan(CaptureState.DegradationReason)
    case degradationEnded
    case failed(DomainError)
    case teardown
}

public extension CaptureState {
    /// Applies an event, returning the next state or nil when the event does not apply.
    ///
    /// Returning nil rather than silently staying put is deliberate: an event arriving in a
    /// state that cannot handle it is a bug somewhere, and a machine that absorbs it makes
    /// that bug invisible. The caller logs it.
    func applying(_ event: CaptureEvent) -> CaptureState? {
        switch (self, event) {
        case (.idle, .configure):
            return .configuring
        case (.configuring, .configured):
            return .ready

        case (.ready, .shutterPressed), (.degraded, .shutterPressed):
            return .capturing
        case (.capturing, .frameAcquired):
            return .persisting

        // The durable write completed. Only now is the capture real, and only now may the
        // interface say so.
        case (.persisting, .persisted):
            return .ready

        case (_, .interrupted(let reason)) where isTerminal == false:
            return .interrupted(reason: reason)
        case (.interrupted, .interruptionEnded):
            return .ready

        case (.ready, .degradationBegan(let reason)), (.capturing, .degradationBegan(let reason)):
            return .degraded(reason: reason)
        case (.degraded, .degradationEnded):
            return .ready

        case (_, .failed(let error)):
            return .failed(error)
        case (_, .teardown):
            return .idle

        default:
            return nil
        }
    }
}
