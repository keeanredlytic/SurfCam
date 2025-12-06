import AVFoundation

/// Zoom behavior modes
enum ZoomMode: Equatable {
    case fixed(CGFloat)        // e.g. 1.0x, 2.0x - locked zoom
    case autoSubjectSize       // Keep subject at ~40% of frame height
    case off                   // No zoom changes at all
    
    var displayName: String {
        switch self {
        case .fixed(let factor): return String(format: "%.1fx", factor)
        case .autoSubjectSize: return "Auto"
        case .off: return "Manual"
        }
    }
}

/// Controls camera zoom with multiple modes
class ZoomController: ObservableObject {
    @Published var zoomFactor: CGFloat = 1.0
    @Published var mode: ZoomMode = .fixed(1.0)
    @Published var isSearching = false
    
    weak var videoDevice: AVCaptureDevice?
    weak var cameraManager: CameraSessionManager?
    
    let minZoom: CGFloat = 1.0
    let maxZoom: CGFloat = 4.0
    let defaultZoom: CGFloat = 1.0
    let zoomStep: CGFloat = 0.1
    
    // Auto subject size parameters
    let targetSubjectHeight: CGFloat = 0.4  // Target: 40% of frame
    let subjectHeightTolerance: CGFloat = 0.1  // ±10% tolerance
    
    // Search mode state
    private var framesWithoutTarget = 0
    private let searchThreshold = 10
    
    // MARK: - Mode-based zoom control
    
    /// Call this each tracking frame to update zoom based on current mode
    func updateZoom(for targetHeight: CGFloat?) {
        switch mode {
        case .fixed(let factor):
            setZoomLevel(factor)
            
        case .autoSubjectSize:
            if let height = targetHeight {
                adjustZoomForSubjectHeight(height)
            }
            
        case .off:
            // Don't touch zoom from code
            break
        }
    }
    
    /// Adjust zoom to keep subject at target height
    private func adjustZoomForSubjectHeight(_ currentHeight: CGFloat) {
        guard currentHeight > 0.05 else { return }  // Ignore tiny detections
        
        let error = targetSubjectHeight - currentHeight
        
        // Only adjust if outside tolerance
        if abs(error) < subjectHeightTolerance { return }
        
        // Calculate zoom adjustment
        // If subject is too small (error > 0), zoom in
        // If subject is too large (error < 0), zoom out
        let zoomAdjustment = error * 0.5  // Gentle adjustment
        let newZoom = max(minZoom, min(maxZoom, zoomFactor + zoomAdjustment))
        
        setZoomLevel(newZoom)
    }
    
    // MARK: - Search mode (for GPS+AI)
    
    func targetExpectedButNotFound() {
        framesWithoutTarget += 1
        
        if framesWithoutTarget > searchThreshold {
            isSearching = true
            // Only zoom in if in auto mode
            if case .autoSubjectSize = mode {
                gentlyZoomIn()
            }
        }
    }
    
    func targetFound() {
        framesWithoutTarget = 0
        isSearching = false
    }
    
    func targetOutsideFOV() {
        framesWithoutTarget = 0
        isSearching = false
    }
    
    // MARK: - Direct zoom controls
    
    func gentlyZoomIn() {
        let newZoom = min(maxZoom, zoomFactor + zoomStep)
        setZoomLevel(newZoom)
    }
    
    func gentlyZoomOutToward(_ target: CGFloat) {
        let newZoom = max(target, zoomFactor - zoomStep)
        setZoomLevel(newZoom)
    }
    
    func setZoomLevel(_ level: CGFloat) {
        let clamped = max(minZoom, min(maxZoom, level))
        
        // Use camera manager if available, otherwise direct device access
        if let manager = cameraManager {
            manager.setZoom(clamped)
            DispatchQueue.main.async {
                self.zoomFactor = clamped
            }
        } else if let device = videoDevice {
            setZoom(clamped, on: device)
        }
    }
    
    func resetZoom() {
        setZoomLevel(defaultZoom)
        framesWithoutTarget = 0
        isSearching = false
    }
    
    private func setZoom(_ z: CGFloat, on device: AVCaptureDevice) {
        guard !device.isRampingVideoZoom else { return }
        
        do {
            try device.lockForConfiguration()
            let maxDeviceZoom = device.activeFormat.videoMaxZoomFactor
            let clampedZoom = max(1.0, min(z, maxDeviceZoom))
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
            
            DispatchQueue.main.async {
                self.zoomFactor = clampedZoom
            }
        } catch {
            print("Zoom error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - FOV calculation for GPS
    
    /// Get approximate horizontal FOV for current zoom level
    /// Used for GPS → expectedX mapping
    var currentHFOV: Double {
        // Rough approximation based on zoom
        // iPhone wide camera is ~60° at 1x
        if zoomFactor < 1.4 {
            return 60  // Wide
        } else if zoomFactor < 2.4 {
            return 45  // Mid
        } else {
            return 30  // Tele-ish
        }
    }
}

