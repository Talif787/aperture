import ApertureDomain
@preconcurrency import AVFoundation
import Foundation

/// Drives AVCaptureSession and reports its state through the domain's state machine.
///
/// The machine lives in ApertureDomain and is tested there, on Linux, with no camera. This
/// type's only job is to translate AVFoundation's notifications into the events that
/// machine understands, and to make sure every acquisition is persisted before the caller
/// is told it happened.
///
/// **Not device-verified.** This compiles and its state translation is tested, but no
/// frame has ever been acquired by it on hardware. Session interruption behaviour, the
/// real cost of configuration, and what the preview looks like under load are all unknown.
@MainActor
@Observable
public final class CameraCaptureSession {
    public private(set) var state: CaptureState = .idle
    public private(set) var lastError: DomainError?

    /// Exposed so a SwiftUI layer can attach a preview without reaching into the session.
    public nonisolated let session = AVCaptureSession()

    private let writer: any MediaWriting
    private let conditions: any DeviceConditionProviding
    private let photoOutput = AVCapturePhotoOutput()

    private var delegate: PhotoCaptureDelegate?
    private var observers: [NSObjectProtocol] = []

    public init(writer: any MediaWriting, conditions: any DeviceConditionProviding) {
        self.writer = writer
        self.conditions = conditions
    }

    // MARK: Lifecycle

    /// Requests camera access and configures the session.
    ///
    /// Authorization is asked for here rather than at launch. A permission prompt on first
    /// launch, before the person has seen why the app needs a camera, is the prompt most
    /// likely to be denied, and a denial is close to permanent.
    public func prepare() async {
        apply(.configure)

        let granted = await Self.requestCameraAccess()
        guard granted else {
            fail(with: .permissionDenied(permission: "camera"))
            return
        }

        do {
            try configureSession()
        } catch let error as DomainError {
            fail(with: error)
            return
        } catch {
            fail(with: .deviceCapabilityUnavailable(capability: "camera"))
            return
        }

        observeInterruptions()

        // Started off the main actor. Starting a session blocks for a noticeable time, and
        // doing it on the main thread is a stall the user sees as the app freezing while
        // the camera opens.
        let session = self.session
        await Task.detached { session.startRunning() }.value

        apply(.configured)
    }

    public func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        let session = self.session
        Task.detached { session.stopRunning() }

        apply(.teardown)
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            throw DomainError.deviceCapabilityUnavailable(capability: "rear camera")
        }

        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            throw DomainError.deviceCapabilityUnavailable(capability: "photo output")
        }

        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
    }

    // MARK: Capture

    /// Captures one photo and returns only once it is durable.
    ///
    /// The ordering is the product's central promise, so it is worth naming each step:
    /// refuse before acquiring if storage is short, acquire, persist, and only then report
    /// success. A capture that fires and fails to persist is the single outcome this must
    /// never produce, because the inspector saw the shutter and will believe the evidence
    /// exists.
    public func capturePhoto() async throws -> WrittenMedia {
        guard state.acceptsCapture else {
            throw DomainError.illegalStateTransition(
                from: String(describing: state), to: "capturing"
            )
        }

        let available = try await writer.availableBytes()
        if StoragePolicy.disposition(availableBytes: available) == .blocked {
            let needed = StoragePolicy.blockingThreshold - available
            let error = DomainError.storageFull(bytesNeeded: needed)
            fail(with: error)
            throw error
        }

        apply(.shutterPressed)

        let data: Data
        do {
            data = try await acquirePhotoData()
        } catch {
            let domainError = (error as? DomainError)
                ?? .unrecoverable(code: "ERR-4805", correlationID: "capture.acquire")
            fail(with: domainError)
            throw domainError
        }

        apply(.frameAcquired)

        do {
            let written = try await writer.write(data, kind: .photo)
            apply(.persisted)
            return written
        } catch {
            let domainError = (error as? DomainError)
                ?? .unrecoverable(code: "ERR-4806", correlationID: "capture.persist")
            fail(with: domainError)
            throw domainError
        }
    }

    private func acquirePhotoData() async throws -> Data {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = conditions.thermalState.requiresReducedResolution
            ? .speed
            : .quality

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { result in
                continuation.resume(with: result)
            }

            // Held for the duration. AVFoundation keeps only an unowned reference to the
            // delegate, so dropping it here would deallocate it before the photo arrives
            // and the continuation would never resume.
            self.delegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: Interruptions

    private func observeInterruptions() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.apply(.interrupted(Self.reason(from: notification)))
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.apply(.interruptionEnded)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fail(with: .unrecoverable(
                        code: "ERR-4807", correlationID: "capture.runtime"
                    ))
                }
            }
        )
    }

    private static func reason(
        from notification: Notification
    ) -> CaptureState.InterruptionReason {
        guard
            let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
            let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        else {
            return .hardwareDisconnected
        }

        switch reason {
        case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient:
            return .anotherApplication
        case .videoDeviceNotAvailableInBackground:
            return .backgrounded
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return .anotherApplication
        case .videoDeviceNotAvailableDueToSystemPressure:
            return .hardwareDisconnected
        @unknown default:
            return .hardwareDisconnected
        }
    }

    // MARK: State

    /// Applies an event, ignoring transitions the machine rejects.
    ///
    /// Ignoring rather than crashing is deliberate. AVFoundation delivers notifications in
    /// orders the documentation does not promise, including an interruption that ends
    /// before it began, and a state machine that traps on an unexpected order would turn a
    /// framework quirk into a crash in the field.
    private func apply(_ event: CaptureEvent) {
        guard let next = state.applying(event) else { return }
        state = next
    }

    private func fail(with error: DomainError) {
        lastError = error
        apply(.failed(error))
    }
}

/// Bridges AVFoundation's delegate callback to an async continuation.
///
/// A separate object rather than a conformance on the session, because it must be an
/// NSObject and must survive until the callback fires.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(DomainError.unrecoverable(
                code: "ERR-4808", correlationID: "capture.representation"
            )))
            return
        }

        completion(.success(data))
    }
}
