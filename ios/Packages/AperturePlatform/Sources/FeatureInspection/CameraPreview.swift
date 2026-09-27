@preconcurrency import AVFoundation
import SwiftUI

/// The live viewfinder.
///
/// A UIViewRepresentable rather than anything SwiftUI-native, because the preview layer is
/// a CALayer and there is no SwiftUI equivalent. The layer is attached to the view's own
/// backing layer, so it resizes with the view instead of needing a manual frame update on
/// every layout pass.
public struct CameraPreview: UIViewRepresentable {
    private let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        // The session is fixed for the lifetime of the screen, so there is nothing to
        // update. Reassigning it here would tear down and rebuild the preview on every
        // SwiftUI state change, which is a visible flicker.
    }

    /// A view whose backing layer is the preview layer.
    public final class PreviewView: UIView {
        public override static var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe by construction: layerClass above guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
