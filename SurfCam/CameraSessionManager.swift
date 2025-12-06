import AVFoundation
import Photos
import UIKit

// MARK: - Resolution Enum

enum CaptureResolution: String, CaseIterable {
    case hd1080 = "1080p"   // 1920x1080
    case uhd4K = "4K"       // 3840x2160
    
    var displayName: String { rawValue }
}

/// Centralized camera session manager that handles:
/// - Preview layer
/// - Vision frame output
/// - Video recording
class CameraSessionManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastRecordingURL: URL?
    @Published var recordingError: String?
    @Published var isSessionRunning = false
    @Published var currentResolutionDisplay: String = "1080p"
    
    // MARK: - Resolution & FPS Settings
    var resolution: CaptureResolution = .hd1080
    var targetFPS: Double = 30.0
    
    // MARK: - AVFoundation Components
    let session = AVCaptureSession()
    private(set) var videoDevice: AVCaptureDevice?
    private(set) var videoInput: AVCaptureDeviceInput?
    private(set) var videoDataOutput: AVCaptureVideoDataOutput?
    private(set) var movieOutput: AVCaptureMovieFileOutput?
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    
    // MARK: - Queues
    private let sessionQueue = DispatchQueue(label: "CameraSessionManager.sessionQueue")
    private let videoOutputQueue = DispatchQueue(label: "CameraSessionManager.videoOutputQueue")
    
    // MARK: - Delegates
    weak var videoFrameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    
    // MARK: - Recording State
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    
    // MARK: - Setup
    
    func setupSession() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }
    
    private func configureSession() {
        session.beginConfiguration()
        
        // Clear existing inputs/outputs for reconfiguration
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        
        // 1. Pick the back wide camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back) else {
            print("❌ No back camera available")
            session.commitConfiguration()
            return
        }
        
        videoDevice = device
        
        // 2. Configure resolution (1080p vs 4K)
        switch resolution {
        case .uhd4K:
            if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
                print("📹 Using 4K (3840×2160)")
                DispatchQueue.main.async { self.currentResolutionDisplay = "4K" }
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
                print("⚠️ 4K not supported, falling back to 1080p")
                DispatchQueue.main.async { self.currentResolutionDisplay = "1080p" }
            }
        case .hd1080:
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
                print("📹 Using 1080p (1920×1080)")
                DispatchQueue.main.async { self.currentResolutionDisplay = "1080p" }
            } else {
                session.sessionPreset = .high
                print("⚠️ 1080p not supported, using default preset")
                DispatchQueue.main.async { self.currentResolutionDisplay = "Auto" }
            }
        }
        
        // 3. Lock device to target FPS (30 by default)
        configureFrameRate(device: device, fps: targetFPS)
        
        // 4. Add video input
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
        } catch {
            print("❌ Could not create video input: \(error)")
            session.commitConfiguration()
            return
        }
        
        // 4b. Add audio input (microphone)
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    print("✅ Audio input added")
                }
            } catch {
                print("⚠️ Could not add audio input: \(error)")
                // Continue without audio
            }
        }
        
        // 5. Add video data output (for Vision tracking)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoDataOutput = videoOutput
            
            // Apply stored delegate if one was set before session setup
            if let delegate = videoFrameDelegate {
                videoOutput.setSampleBufferDelegate(delegate, queue: videoOutputQueue)
                print("✅ Video frame delegate applied after session setup")
            }
            
            // Configure connection for video orientation
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
        }
        
        // 6. Add movie file output (for recording)
        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            self.movieOutput = movieOutput
            
            // Configure for high quality with stabilization
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        }
        
        session.commitConfiguration()
        
        // Configure autofocus and exposure
        configureFocusAndExposure(on: device)
        
        print("✅ Camera session configured: \(resolution.displayName) @ \(Int(targetFPS)) FPS")
    }
    
    // MARK: - Frame Rate Configuration
    
    /// Lock the device to a specific frame rate (e.g., 30 FPS)
    private func configureFrameRate(device: AVCaptureDevice, fps: Double) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            let targetDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            
            // Find the best format that supports this FPS at current resolution
            var bestFormat: AVCaptureDevice.Format?
            var bestDimensions: CMVideoDimensions = CMVideoDimensions(width: 0, height: 0)
            
            let targetWidth: Int32 = resolution == .uhd4K ? 3840 : 1920
            
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                
                // Skip if not matching our target resolution
                if dims.width != targetWidth { continue }
                
                // Check if this format supports our target FPS
                for range in format.videoSupportedFrameRateRanges {
                    if range.minFrameDuration <= targetDuration && targetDuration <= range.maxFrameDuration {
                        // Prefer the format with highest resolution
                        if dims.width >= bestDimensions.width && dims.height >= bestDimensions.height {
                            bestFormat = format
                            bestDimensions = dims
                        }
                    }
                }
            }
            
            if let format = bestFormat {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = targetDuration
                device.activeVideoMaxFrameDuration = targetDuration
                print("🎯 Locked FPS to \(Int(fps)) on format: \(bestDimensions.width)×\(bestDimensions.height)")
            } else {
                // Fallback: just set frame duration on current format
                device.activeVideoMinFrameDuration = targetDuration
                device.activeVideoMaxFrameDuration = targetDuration
                print("🎯 Attempted to lock FPS to \(Int(fps)) on current format")
            }
        } catch {
            print("⚠️ Could not lock frame rate: \(error)")
        }
    }
    
    // MARK: - Resolution Switching
    
    /// Safely switch between 1080p and 4K while session is running
    func setResolution(_ newResolution: CaptureResolution) {
        guard newResolution != resolution else { return }
        
        resolution = newResolution
        
        // Reconfigure session safely on background queue
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let wasRunning = self.session.isRunning
            
            if wasRunning {
                self.session.stopRunning()
            }
            
            self.configureSession()
            
            if wasRunning {
                self.session.startRunning()
            }
            
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }
    
    /// Configure autofocus and exposure - "set and forget"
    private func configureFocusAndExposure(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // Continuous autofocus
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // Smooth autofocus transitions
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            
            // Continuous auto exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            // Monitor subject area changes
            device.isSubjectAreaChangeMonitoringEnabled = true
            
            device.unlockForConfiguration()
            print("✅ Autofocus and exposure configured")
        } catch {
            print("❌ Focus/exposure config error: \(error)")
        }
    }
    
    // MARK: - Session Control
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                }
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
            }
        }
    }
    
    // MARK: - Video Frame Delegate
    
    func setVideoFrameDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        videoFrameDelegate = delegate
        // Apply immediately if output exists, otherwise it will be applied in configureSession
        if let output = videoDataOutput {
            output.setSampleBufferDelegate(delegate, queue: videoOutputQueue)
            print("✅ Video frame delegate set immediately")
        } else {
            print("⏳ Video frame delegate stored (will apply after session setup)")
        }
    }
    
    // MARK: - Preview Layer
    
    func createPreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        
        // Set initial orientation
        DispatchQueue.main.async { [weak self] in
            self?.updateOrientation()
        }
        
        return layer
    }
    
    // MARK: - Recording
    
    func startRecording() {
        guard let movieOutput = movieOutput, !isRecording else { return }
        
        // Create unique filename
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "SurfCam-\(timestamp).mov"
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documentsPath.appendingPathComponent(filename)
        
        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)
        
        sessionQueue.async { [weak self] in
            movieOutput.startRecording(to: outputURL, recordingDelegate: self!)
            
            DispatchQueue.main.async {
                self?.isRecording = true
                self?.recordingStartTime = Date()
                self?.recordingError = nil
                self?.startRecordingTimer()
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        movieOutput?.stopRecording()
        stopRecordingTimer()
    }
    
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    
    // MARK: - Save to Photos
    
    func saveToPhotoLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    completion(false, NSError(domain: "CameraSessionManager",
                                            code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }
    }
    
    // MARK: - Zoom Control
    
    func setZoom(_ factor: CGFloat) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 6.0)
            let clampedZoom = max(1.0, min(factor, maxZoom))
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
        } catch {
            print("Zoom error: \(error)")
        }
    }
    
    // MARK: - Orientation
    
    func updateOrientation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOrientation()
            }
            return
        }
        
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        
        let interfaceOrientation = scene.interfaceOrientation
        
        let rotationAngle: CGFloat
        switch interfaceOrientation {
        case .portrait: rotationAngle = 90
        case .portraitUpsideDown: rotationAngle = 270
        case .landscapeLeft: rotationAngle = 180
        case .landscapeRight: rotationAngle = 0
        default: rotationAngle = 90
        }
        
        // Update video output connection (for Vision processing)
        if let connection = videoDataOutput?.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        
        // Update movie output connection (for recording)
        if let connection = movieOutput?.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        
        // Update preview layer connection - this is what rotates the on-screen preview
        guard let previewLayer = previewLayer,
              let layerConnection = previewLayer.connection else {
            return
        }
        
        // Prefer the newer rotationAngle API when available (iOS 17+)
        if layerConnection.isVideoRotationAngleSupported(rotationAngle) {
            layerConnection.videoRotationAngle = rotationAngle
        } else {
            // Fallback to videoOrientation for older OS versions
            let videoOrientation: AVCaptureVideoOrientation
            switch interfaceOrientation {
            case .portrait: videoOrientation = .portrait
            case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
            case .landscapeLeft: videoOrientation = .landscapeLeft
            case .landscapeRight: videoOrientation = .landscapeRight
            default: videoOrientation = .portrait
            }
            layerConnection.videoOrientation = videoOrientation
        }
        
        // Ensure no additional transform is applied
        previewLayer.setAffineTransform(.identity)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraSessionManager: AVCaptureFileOutputRecordingDelegate {
    
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        print("📹 Recording started: \(fileURL.lastPathComponent)")
    }
    
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.recordingDuration = 0
            
            if let error = error {
                self?.recordingError = error.localizedDescription
                print("❌ Recording error: \(error)")
                return
            }
            
            self?.lastRecordingURL = outputFileURL
            print("✅ Recording saved: \(outputFileURL.lastPathComponent)")
            
            // Optionally auto-save to Photos
            self?.saveToPhotoLibrary(url: outputFileURL) { success, saveError in
                if success {
                    print("✅ Video saved to Photos")
                } else if let saveError = saveError {
                    print("❌ Failed to save to Photos: \(saveError)")
                }
            }
        }
    }
}

