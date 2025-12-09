import SwiftUI
import AVFoundation

struct CameraView: UIViewRepresentable {
    @ObservedObject var faceTracker: FaceTracker
    @ObservedObject var cameraManager: CameraSessionManager
    var zoomController: ZoomController?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(faceTracker: faceTracker)
    }
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        
        // Use the centralized camera manager
        let previewLayer = cameraManager.createPreviewLayer()
        previewLayer.frame = view.bounds
        previewLayer.needsDisplayOnBoundsChange = true
        view.layer.addSublayer(previewLayer)
        
        context.coordinator.previewLayer = previewLayer
        
        // Set the face tracker as the video frame delegate
        cameraManager.setVideoFrameDelegate(context.coordinator)
        
        // Give zoom controller access to the camera manager
        zoomController?.cameraManager = cameraManager
        zoomController?.videoDevice = cameraManager.videoDevice
        // And give camera manager an optional back-reference to zoom controller
        cameraManager.zoomController = zoomController
        
        // Setup and start the session
        cameraManager.setupSession()
        
        // Store camera manager reference in coordinator
        context.coordinator.cameraManager = cameraManager
        
        // Observe orientation changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        // Start device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Update orientation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cameraManager.updateOrientation()
            faceTracker.updateOrientation()
            cameraManager.startSession()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Keep preview layer in sync with view bounds
        context.coordinator.previewLayer?.frame = uiView.bounds
        
        // Update orientation when layout/orientation changes
        // This is called when SwiftUI detects layout changes (including rotation)
        DispatchQueue.main.async {
            cameraManager.updateOrientation()
        faceTracker.updateOrientation()
        }
    }
    
    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let faceTracker: FaceTracker
        var previewLayer: AVCaptureVideoPreviewLayer?
        weak var cameraManager: CameraSessionManager?
        
        init(faceTracker: FaceTracker) {
            self.faceTracker = faceTracker
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            faceTracker.process(sampleBuffer)
        }
        
        @objc func orientationChanged() {
                DispatchQueue.main.async { [weak self] in
                self?.cameraManager?.updateOrientation()
                self?.faceTracker.updateOrientation()
            }
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
