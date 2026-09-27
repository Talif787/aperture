import ApertureCapture
import ApertureDesignSystem
import ApertureDomain
import SwiftUI

/// The capture screen.
///
/// Every decision here is shaped by where this is used: outdoors, one-handed, possibly in
/// gloves, possibly in rain, by someone who cannot come back tomorrow if it goes wrong.
///
/// **Not device-verified.** This compiles and its state handling is exercised, but it has
/// never been rendered on a phone. Nothing here has been checked against a real viewfinder,
/// in sunlight, or with a thumb.
public struct CaptureScreen: View {
    @State private var session: CameraCaptureSession
    @State private var conditions: DeviceConditionMonitor
    @State private var capturedCount: Int = 0
    @State private var isCapturing = false

    private let onCaptured: (WrittenMedia) -> Void

    public init(
        session: CameraCaptureSession,
        conditions: DeviceConditionMonitor = DeviceConditionMonitor(),
        onCaptured: @escaping (WrittenMedia) -> Void
    ) {
        _session = State(initialValue: session)
        _conditions = State(initialValue: conditions)
        self.onCaptured = onCaptured
    }

    public var body: some View {
        ZStack {
            CameraPreview(session: session.session)
                .ignoresSafeArea()

            VStack {
                statusBanner
                Spacer()
                controls
            }
            .padding(Tokens.Spacing.md)
        }
        .background(Tokens.Color.surface)
        .task {
            conditions.start()
            await session.prepare()
        }
        .onDisappear {
            conditions.stop()
            session.tearDown()
        }
        .alert(
            "Capture unavailable",
            isPresented: .constant(session.lastError != nil),
            presenting: session.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(Self.message(for: error))
        }
    }

    // MARK: Status

    /// A banner rather than a toast or an alert.
    ///
    /// Conditions that degrade capture persist, and a message that disappears after three
    /// seconds is a message the inspector will miss while looking at a roof. It stays until
    /// the condition does.
    @ViewBuilder
    private var statusBanner: some View {
        if let message = degradationMessage {
            Text(message)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Color.textPrimary)
                .padding(Tokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Color.warning.opacity(0.9), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var degradationMessage: String? {
        switch session.state {
        case .interrupted(let reason):
            return Self.message(for: reason)
        case .degraded(let reason):
            return Self.message(for: reason)
        case .configuring:
            return String(localized: "Starting the camera", comment: "Shown while the capture session configures")
        default:
            break
        }

        if conditions.thermalState >= .serious {
            // Named plainly. "Thermal state serious" means nothing to an inspector; the
            // actionable part is that captures still work and analysis is reduced.
            return String(
                localized: "The phone is hot. Photos still save; on-device analysis is paused.",
                comment: "Shown when thermal pressure reduces inference"
            )
        }

        return nil
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.xl) {
            capturedIndicator

            Button {
                Task { await capture() }
            } label: {
                Circle()
                    .strokeBorder(Tokens.Color.textPrimary, lineWidth: 4)
                    .background(Circle().fill(isCapturing ? Tokens.Color.pending : Tokens.Color.surfaceElevated))
                    .frame(
                        width: Tokens.Size.captureControl,
                        height: Tokens.Size.captureControl
                    )
            }
            // The touch target is deliberately large. The device is held one-handed by
            // someone who may be wearing gloves, and a missed shutter is a capture that
            // did not happen at a site nobody is coming back to.
            .frame(minWidth: Tokens.Size.minimumTouchTarget, minHeight: Tokens.Size.minimumTouchTarget)
            .disabled(!session.state.acceptsCapture || isCapturing)
            .accessibilityLabel(Text("Capture photo", comment: "Shutter button"))
            .accessibilityHint(Text("Saves a photo to this finding"))

            // Balances the indicator so the shutter sits centred, without a second control
            // competing for a thumb that is aiming for the shutter.
            capturedIndicator.opacity(0)
        }
    }

    private var capturedIndicator: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: "photo.stack")
                .font(.system(size: Tokens.Size.iconMedium))
            Text("\(capturedCount)")
                .font(Tokens.Typography.body)
                .monospacedDigit()
        }
        .foregroundStyle(Tokens.Color.textPrimary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Captured"))
        .accessibilityValue(Text("\(capturedCount)"))
    }

    private func capture() async {
        isCapturing = true
        defer { isCapturing = false }

        do {
            let written = try await session.capturePhoto()
            capturedCount += 1
            onCaptured(written)
        } catch {
            // The alert is driven by session.lastError, which the session has already set.
            // Swallowing here rather than handling twice keeps one source of truth for
            // what went wrong.
        }
    }

    // MARK: Copy

    private static func message(for reason: CaptureState.InterruptionReason) -> String {
        switch reason {
        case .incomingCall:
            return String(localized: "Paused for a call", comment: "Capture interrupted by a phone call")
        case .anotherApplication:
            return String(localized: "Another app is using the camera", comment: "Capture interrupted by another app")
        case .hardwareDisconnected:
            return String(localized: "The camera is unavailable", comment: "Capture interrupted by hardware")
        case .backgrounded:
            return String(localized: "Paused while in the background", comment: "Capture interrupted by backgrounding")
        }
    }

    private static func message(for reason: CaptureState.DegradationReason) -> String {
        switch reason {
        case .thermalPressure:
            return String(
                localized: "The phone is hot. Photos still save; analysis is paused.",
                comment: "Capture degraded by heat"
            )
        case .lowPowerMode:
            return String(
                localized: "Low Power Mode is on. Photos still save.",
                comment: "Capture degraded by low power mode"
            )
        case .storagePressure:
            return String(
                localized: "Storage is low. Sync to free space.",
                comment: "Capture degraded by storage pressure"
            )
        }
    }

    private static func message(for error: DomainError) -> String {
        switch error {
        case .permissionDenied:
            return String(
                localized: "Aperture needs camera access. Enable it in Settings.",
                comment: "Camera permission denied"
            )
        case .storageFull:
            // The number is deliberately absent. "Free 340 MB" is a number the inspector
            // cannot act on in the field; syncing is the action that helps.
            return String(
                localized: "Not enough space to capture. Sync to free space.",
                comment: "Storage full"
            )
        case .deviceCapabilityUnavailable(let capability):
            return String(
                localized: "This device has no \(capability).",
                comment: "Missing hardware capability"
            )
        default:
            return String(
                localized: "The camera stopped unexpectedly. Try again.",
                comment: "Generic capture failure"
            )
        }
    }
}
