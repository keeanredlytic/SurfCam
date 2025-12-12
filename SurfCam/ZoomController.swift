import AVFoundation

/// Zoom presets expressed in Camera-app style stops, scaled from the device's ultra-wide base.
enum ZoomPreset: String, CaseIterable, Identifiable {
    case ultraWide05    // UI: 0.5x – true ultra-wide
    case wide1          // UI: 1x   – main
    case tele2          // UI: 2x   – mid tele
    case tele4          // UI: 4x   – long tele
    
    var id: String { displayName }
    
    /// Label for UI buttons.
    var displayName: String {
        switch self {
        case .ultraWide05: return "0.5x"
        case .wide1:       return "1x"
        case .tele2:       return "2x"
        case .tele4:       return "4x"
        }
    }
    
    /// UI-facing zoom factor (Camera app semantics).
    var uiZoomFactor: CGFloat {
        switch self {
        case .ultraWide05: return 0.5
        case .wide1:       return 1.0
        case .tele2:       return 2.0
        case .tele4:       return 4.0
        }
    }
    
    /// Preset-based HFOV used for GPS math (approximate but consistent).
    var anchorHFOV: Double {
        switch self {
        case .ultraWide05: return 110.0  // 0.5x – very wide
        case .wide1:       return 78.0   // 1x – main
        case .tele2:       return 40.0   // 2x – mid tele
        case .tele4:       return 22.0   // 4x – long tele
        }
    }
    
    /// Lens-specific center bias in degrees (persisted).
    var lensCenterBiasDegrees: CGFloat {
        LensCalibrationManager.shared.bias(for: self)
    }
    
    /// Convert UI stop to a device zoom factor for the current back camera.
    /// On multi-cam devices, minAvailableVideoZoomFactor is typically the 0.5x lens.
    func deviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let base = device.minAvailableVideoZoomFactor
        switch self {
        case .ultraWide05: return base              // 0.5x
        case .wide1:       return base * 2.0        // 1x
        case .tele2:       return base * 4.0        // 2x
        case .tele4:       return base * 8.0        // 4x
        }
    }
}

/// Zoom behavior modes
enum ZoomMode: Equatable {
    case fixed(CGFloat)        // e.g. 1.0x, 2.0x - locked zoom
    case autoSubjectSize       // Keep subject at ~40% of frame height (legacy / unused)
    case autoDistance          // Distance-based auto zoom
    case autoSubjectWidth      // Vision-based width auto zoom (new)
    case off                   // No zoom changes at all
    
    var displayName: String {
        switch self {
        case .fixed(let factor): return String(format: "%.1fx", factor)
        case .autoSubjectSize: return "Auto"
        case .autoDistance: return "AutoDist"
        case .autoSubjectWidth: return "AutoWidth"
        case .off: return "Manual"
        }
    }
}

/// Controls camera zoom with multiple modes
final class ZoomController: ObservableObject {
    // MARK: - Public read-only state
    @Published private(set) var currentPreset: ZoomPreset = .wide1 {
        didSet {
            currentHFOV = currentPreset.anchorHFOV
        }
    }
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var currentHFOV: Double = ZoomPreset.wide1.anchorHFOV
    
    @Published var mode: ZoomMode = .fixed(1.0) {
        didSet {
            if case .autoSubjectWidth = mode {
                narrowFrames = 0
                wideFrames = 0
            }
        }
    }
    @Published var isSearching = false

    // Auto-distance state
    private var lastZoomDistanceMeters: Double?
    private var basePresetWhenAutoStarted: ZoomPreset?
    // Auto-subject-width persistence counters
    private var narrowFrames = 0
    private var wideFrames = 0
    
    // MARK: - Dependencies
    weak var videoDevice: AVCaptureDevice?
    weak var cameraManager: CameraSessionManager?
    
    // MARK: - Limits / steps
    let minZoom: CGFloat = 0.5    // allow ultra-wide on multi-cam devices
    let maxZoom: CGFloat = 8.0    // manual/UI cap; device clamp handles higher (auto can exceed)
    let defaultZoom: CGFloat = 1.0
    let zoomStep: CGFloat = 0.1
    
    // Auto subject size parameters
    let targetSubjectHeight: CGFloat = 0.4  // Target: 40% of frame
    let subjectHeightTolerance: CGFloat = 0.1  // ±10% tolerance
    
    // Auto-distance parameters
    var autoDistanceZoomFloor: CGFloat = 1.5  // minimum zoom when autoDistance is active
    
    // Search mode state
    private var framesWithoutTarget = 0
    private let searchThreshold = 10
    
    // MARK: - Preset application
    
    /// Call this when user taps a zoom preset button (0.5x, 1x, 2x, 4x).
    func applyPreset(_ preset: ZoomPreset) {
        currentPreset = preset
        
        // For internal state (FOV/GPS math) use UI factor
        mode = .fixed(preset.uiZoomFactor)
        
        // Apply to hardware using device-specific scaling
        if let device = cameraManager?.videoDevice {
            let deviceFactor = preset.deviceZoomFactor(for: device)
            cameraManager?.setZoom(deviceFactor)
        } else {
            // Fallback: still publish the UI factor
            setZoomLevel(preset.uiZoomFactor)
        }
    }
    
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
            
        case .autoDistance:
            // Distance-based zoom is driven elsewhere (CameraScreen.tickTracking)
            break

        case .autoSubjectWidth:
            // Vision-driven width auto zoom is driven from CameraScreen
            break

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
        } else {
            // Still publish the change even if no device is attached yet
            DispatchQueue.main.async {
                self.zoomFactor = clamped
            }
        }
    }

    /// Allow camera layer to push the actual device zoom back to the controller.
    func syncZoomFactorFromDevice(_ value: CGFloat) {
        DispatchQueue.main.async {
            self.zoomFactor = value
        }
    }

    // MARK: - Auto Distance toggles
    func enableAutoDistance() {
        guard case .autoDistance = mode else {
            basePresetWhenAutoStarted = currentPreset
            mode = .autoDistance
            return
        }
    }
    
    func disableAutoDistance() {
        guard case .autoDistance = mode else { return }
        
        mode = .fixed(zoomFactor)
        if let base = basePresetWhenAutoStarted {
            applyPreset(base)   // snap back to original preset
        }
        basePresetWhenAutoStarted = nil
        lastZoomDistanceMeters = nil
    }
    
    var isAutoDistanceEnabled: Bool {
        if case .autoDistance = mode { return true }
        return false
    }

    // MARK: - Auto Subject Width toggles
    func enableAutoSubjectWidth() {
        narrowFrames = 0
        wideFrames = 0
        mode = .autoSubjectWidth
    }

    func disableAutoSubjectWidth() {
        mode = .fixed(zoomFactor)
        narrowFrames = 0
        wideFrames = 0
    }

    var isAutoSubjectWidthEnabled: Bool {
        if case .autoSubjectWidth = mode { return true }
        return false
    }

        // MARK: - Vision-driven subject-width auto zoom
    /// Adjusts zoom so the tracked subject stays ~6% of the frame width,
    /// with a ±1% dead zone (0.05–0.07 normalized width).
    func updateZoomForSubjectWidth(
        normalizedWidth: CGFloat?,
        baselineWidth: CGFloat?,           // now unused; kept for signature compatibility
        cameraManager: CameraSessionManager
    ) {
        guard case .autoSubjectWidth = mode else { return }

        guard let width = normalizedWidth, width > 0.0 else { return }

        // 🎯 Target surfer width = 6% of frame
        let targetWidth: CGFloat = 0.06

        // Deadzone: no zoom change if surfer width is within [5%, 7%]
        let innerTolerance: CGFloat = 0.01   // ±1%

        // Outer band: more aggressive response if > 2% away
        let outerTolerance: CGFloat = 0.02   // ±2%

        let diff = width - targetWidth      // >0 => too big, <0 => too small
        let absDiff = abs(diff)

        // --- Persistence: only act if outside inner band for a few frames ---
        if absDiff > innerTolerance {
            if diff < 0 {
                // surfer too small
                narrowFrames &+= 1
                wideFrames = 0
            } else {
                // surfer too large
                wideFrames &+= 1
                narrowFrames = 0
            }
        } else {
            // In the sweet spot, reset counters and do nothing
            narrowFrames = 0
            wideFrames = 0
            return
        }

        let minTriggerFrames = 5

        if narrowFrames < minTriggerFrames && wideFrames < minTriggerFrames {
            return
        }

        let current = zoomFactor
        var targetZoom = current

        // --- Compute how hard to correct, based on how far we are from target ---
        // Normalized 0..1 "error magnitude" beyond the inner tolerance.
        let excess = max(0.0, absDiff - innerTolerance)
        let normError = min(1.0, excess / outerTolerance) // 0 when barely out of band, 1 when way out

        // Base step size in zoom units per adjustment
        let maxStep: CGFloat = 0.25   // maximum zoom change we *aim* for before smoothing
        let minStep: CGFloat = 0.05   // minimum noticeable correction

        // Interpolate step between minStep and maxStep based on how far off we are
        let stepMagnitude = minStep + (maxStep - minStep) * normError

        if diff < 0 {
            // surfer too small → zoom in
            targetZoom = current + stepMagnitude
        } else {
            // surfer too large → zoom out
            targetZoom = current - stepMagnitude
        }

        // Clamp logical zoom range – this is the hard boundary for auto zoom
        let minFactor: CGFloat = 0.5
        let maxFactor: CGFloat = 8.0   // ✅ new cap at 8x
        targetZoom = max(minFactor, min(maxFactor, targetZoom))

        // --- Smoothing: keep your existing zoom-easing logic ---
        let alpha: CGFloat = 0.25
        var newZoom = current + alpha * (targetZoom - current)

        let baseMaxDeltaPerTick: CGFloat = 0.20
        let zoomSlowdown = 1.0 / (1.0 + 0.3 * max(0.0, current - 4.0))
        let maxDeltaPerTick = baseMaxDeltaPerTick * zoomSlowdown
        let delta = max(-maxDeltaPerTick, min(maxDeltaPerTick, newZoom - current))
        newZoom = current + delta

        if abs(newZoom - current) < 0.01 { return }

        cameraManager.setZoom(newZoom)
        DispatchQueue.main.async { self.zoomFactor = newZoom }
    }

// MARK: - Distance → Zoom mapping
    private func targetZoom(for distanceMeters: Double) -> CGFloat {
        let d = max(0.0, distanceMeters)
        
        // Tunable thresholds for surf distance ranges
        let near: Double = 30.0   // close-in surfing
        let mid: Double  = 80.0   // mid-range
        let far: Double  = 150.0  // far-out, long tele
        
        let rawTarget: CGFloat
        if d <= near {
            rawTarget = 1.0   // wider when very close
        } else if d <= mid {
            let t = (d - near) / (mid - near)   // 0..1
            rawTarget = 1.0 + CGFloat(t) * 1.0  // 1.0 → 2.0
        } else if d <= far {
            let t = (d - mid) / (far - mid)     // 0..1
            rawTarget = 2.0 + CGFloat(t) * 2.0  // 2.0 → 4.0
        } else {
            rawTarget = 4.0   // cap at 4x
        }
        
        // Apply zoom floor so we never go super wide in autoDistance
        let base = basePresetWhenAutoStarted?.uiZoomFactor ?? 1.0
        let floorValue = max(autoDistanceZoomFloor, base)
        let floored = max(floorValue, rawTarget)
        
        // Respect overall bounds notionally (0.5x–4x)
        return min(4.0, max(0.5, floored))
    }
    
    // MARK: - Auto distance core update
    func updateZoomForDistance(
        distanceMeters: Double?,
        gpsTrust: CGFloat,
        hasGoodGPS: Bool,
        cameraManager: CameraSessionManager
    ) {
        // Only act in autoDistance mode
        guard case .autoDistance = mode else { return }
        
        // Require decent GPS
        guard hasGoodGPS,
              gpsTrust >= 0.4,
              let distance = distanceMeters else { return }
        
        // Ignore tiny distance jitter
        let distanceDeadband: Double = 2.0 // meters
        if let last = lastZoomDistanceMeters,
           abs(distance - last) < distanceDeadband {
            return
        }
        lastZoomDistanceMeters = distance
        
        let target = targetZoom(for: distance)
        let current = zoomFactor
        
        // Exponential smoothing toward target
        let alpha: CGFloat = 0.15
        var newZoom = current + alpha * (target - current)
        
        // Limit max zoom velocity per tick
        let maxDelta: CGFloat = 0.15
        let delta = max(-maxDelta, min(maxDelta, newZoom - current))
        newZoom = current + delta
        
        // Avoid micro-changes
        if abs(newZoom - current) < 0.01 {
            return
        }
        
        // Let CameraSessionManager clamp to device min/max
        cameraManager.setZoom(newZoom)
        
        DispatchQueue.main.async {
            self.zoomFactor = newZoom
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
            let minDeviceZoom = device.minAvailableVideoZoomFactor
            let maxDeviceZoom = device.activeFormat.videoMaxZoomFactor
            let clampedZoom = max(minDeviceZoom, min(z, maxDeviceZoom))
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
    
    /// Approx horizontal FOV in degrees based on the current anchor preset.
    /// Used only by GPS math – Vision tracking stays in 0..1 normalized coords.
}

