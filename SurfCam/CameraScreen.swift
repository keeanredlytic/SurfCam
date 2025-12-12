import SwiftUI
import Combine
import CoreLocation

final class CameraScreenViewModel: ObservableObject {
    @Published var gpsDistanceMeters: Double?
    @Published var gpsDistanceIsValid: Bool = false
    @Published var latestWatchAccuracy: CLLocationAccuracy?
}

enum TrackingMode: String, CaseIterable {
    case off
    case cameraAI
    case watchGPS
    case gpsAI      // GPS+AI fusion - best of both worlds
}

enum TrackState {
    case searching   // trying to find the surfer
    case locked      // strong visual lock – Vision rules
    case lost        // just lost them – rely on GPS to reacquire
}

struct CameraScreen: View {
    @ObservedObject var api: PanRigAPI
    @ObservedObject var faceTracker: FaceTracker
    @ObservedObject var rigLocationManager: RigLocationManager
    @ObservedObject var gpsTracker: WatchGPSTracker
    @ObservedObject var zoomController: ZoomController
    @ObservedObject var cameraManager: CameraSessionManager
    @StateObject private var viewModel = CameraScreenViewModel()

    // Explicit initializer to keep access public within the module
    init(api: PanRigAPI,
         faceTracker: FaceTracker,
         rigLocationManager: RigLocationManager,
         gpsTracker: WatchGPSTracker,
         zoomController: ZoomController,
         cameraManager: CameraSessionManager) {
        self.api = api
        self.faceTracker = faceTracker
        self.rigLocationManager = rigLocationManager
        self.gpsTracker = gpsTracker
        self.zoomController = zoomController
        self.cameraManager = cameraManager

    }

    // MARK: - Subject width smoothing + auto zoom helper
    private func updateSubjectWidthAndAutoZoom() {
        // 1) Smooth subject width from Vision bbox
        if let bbox = faceTracker.targetBoundingBox {
            let rawWidth = bbox.width       // 0..1 normalized

            // Ignore clearly bogus tiny widths
            guard rawWidth > 0.01 else {
                smoothedSubjectWidth = nil
                subjectWidthFrameCounter = 0
                return
            }

            let alpha: CGFloat = 0.4
            if let prev = smoothedSubjectWidth {
                smoothedSubjectWidth = prev * (1 - alpha) + rawWidth * alpha
            } else {
                smoothedSubjectWidth = rawWidth
            }
            subjectWidthFrameCounter &+= 1
            if subjectWidthFrameCounter % 30 == 0, let w = smoothedSubjectWidth {
                print("🔍 Subject width (smoothed): \(String(format: "%.3f", w))")
            }
            subjectWidthHoldFrames = 5 // keep width alive briefly if bbox flickers
        } else {
            subjectWidthFrameCounter = 0
            if subjectWidthHoldFrames > 0 {
                subjectWidthHoldFrames -= 1
            } else {
                smoothedSubjectWidth = nil
            }
        }

        // 2) Vision-driven auto zoom (skip while in passiveHold)
        guard recoveryMode != .passiveHold else { return }

        guard trackState == .locked else { return }
        guard subjectWidthFrameCounter >= 10 else { return }
        guard let faceCenter = faceTracker.faceCenter else { return }
        let horizontalOffset = abs(faceCenter.x - 0.5)
        let isWellCentered = horizontalOffset < 0.20
        guard isWellCentered else { return }

        if let width = smoothedSubjectWidth,
           let targetWidth = targetSubjectWidth {
            zoomController.updateZoomForSubjectWidth(
                normalizedWidth: width,
                baselineWidth: targetWidth,
                cameraManager: cameraManager
            )
        }
    }

    // MARK: - Passive hold helpers
    private func handleNoTargetFrame() {
        // No valid bbox this frame
        smoothedSubjectWidth = nil

        switch recoveryMode {
        case .none:
            // Just lost target on this frame
            if framesSinceLastTarget == 1 {
                enterPassiveHold()
            }

        case .passiveHold:
            // Still waiting; optional: mark lost after hold duration
            if framesSinceLastTarget == passiveHoldFrames {
                print("⚠️ Still no surfer after \(passiveHoldFrames) frames (passive hold).")
                // Optional: trackState = .lost
            }
        }
    }

    private func enterPassiveHold() {
        recoveryMode = .passiveHold

        // Remember zoom behavior to restore later
        zoomModeBeforeHold = zoomController.mode
        zoomBeforeHold = zoomController.zoomFactor

        // Freeze zoom at current level
        zoomController.mode = .fixed(zoomController.zoomFactor)

        // We do NOT move the servo here (applyVisionFollower only runs when target present)
        print("🛑 Entering passive hold (duck-dive / fall recovery).")
    }

    @State private var trackingMode: TrackingMode = .off
    @State private var trackingTimer: Timer? = nil
    @State private var calibratedBearing: Double? = nil
    @State private var gpsExpectedX: CGFloat? = nil  // Where GPS says target should be on screen
    @State private var isTrackingActive = false  // For GPS+AI mode - requires manual start
    @State private var showSystemPanel = false  // Toggle for system status panel
    @State private var use4K: Bool = false  // Resolution toggle: false = 1080p, true = 4K
    @State private var showCenterDebug: Bool = true
    
    // MARK: - Tracking State Machine
    @State private var trackState: TrackState = .searching
    @State private var consecutiveLockFrames: Int = 0  // How many consecutive frames we've had a good vision lock
    @State private var consecutiveLostFrames: Int = 0  // How many consecutive frames we've had no vision detection
    
    // Thresholds (tweakable)
    private let lockFramesThreshold = 12    // ~1.2s at 10Hz
    private let lostFramesThreshold = 8     // ~0.8s at 10Hz
    
    // MARK: - GPS Quality Metrics (Vision vs GPS alignment)
    @State private var gpsBias: CGFloat = 0.0          // running average (gpsX - visionX)
    @State private var gpsErrorRMS: CGFloat = 0.0      // running RMS of error
    @State private var gpsSampleCount: Int = 0         // how many samples we've accumulated
    
    // Smoothing / scaling constants for GPS trust
    private let gpsEMAAlpha: CGFloat = 0.05           // smaller = smoother, larger = more reactive
    private let gpsMaxScreenErrorForTrust: CGFloat = 0.25  // ~25% of screen width treated as "very bad"
    private let gpsMinSamplesForTrust: Int = 30        // need at least this many samples before trusting
    
    // MARK: - Servo Direction Control
    private let servoMirror: CGFloat = -1.0  // 🔄 Change to 1.0 for normal direction, -1.0 to mirror
    
    // MARK: - Center Bias
    /// Positive = shifts effective center in one direction, negative = other.
    /// Start with +2; if the red dot moves the wrong way, change to -2.
    private let centerBiasDegrees: CGFloat = -0.39

    // MARK: - Distance + Motion State
    /// Latest distance from rig to watch in meters (smoothed GPS)
    @State private var gpsDistanceMeters: CLLocationDistance = 0.0
    /// Latest estimated speed of the watch (m/s) based on last two samples
    @State private var gpsSpeedMps: CLLocationDistance = 0.0
    /// Latest instantaneous bearing from rig → watch (degrees 0–360)
    @State private var gpsBearingRigToWatch: Double?
    /// Smoothed / filtered bearing we actually use for servo control
    @State private var gpsFilteredBearing: Double?
    /// Motion direction heading based on watch movement (previous→current) in degrees
    @State private var gpsMotionHeading: Double?
    /// Last smoothed watch location, for speed + motion heading
    @State private var lastSmoothedWatchLocation: CLLocation?
    /// Smoothed subject width from Vision (for autoSubjectWidth)
    @State private var smoothedSubjectWidth: CGFloat?
    @State private var subjectWidthFrameCounter: Int = 0
    @State private var subjectWidthHoldFrames: Int = 0
    @State private var lastCommandedPanAngle: CGFloat?
    @State private var lastCommandedTiltAngle: CGFloat?
    // MARK: - Short-term loss recovery (duck-dive / quick fall)
    private enum RecoveryMode {
        case none        // normal tracking
        case passiveHold // we just lost the target; hold zoom & pan and wait
    }
    @State private var recoveryMode: RecoveryMode = .none
    @State private var framesSinceLastTarget: Int = 0
    /// How long we "trust" they'll pop back up (20 Hz tick => 60 ≈ 3.0s)
    private let passiveHoldFrames: Int = 60
    /// For restoring zoom behavior
    @State private var zoomModeBeforeHold: ZoomMode = .fixed(1.0)
    @State private var zoomBeforeHold: CGFloat?
    
    // MARK: - Session subject model
    @State private var baselineSubjectWidth: CGFloat?
    @State private var baselineSubjectHeight: CGFloat?
    private var hasLockedSubject: Bool { baselineSubjectWidth != nil }
    // For color lock trigger
    private var pendingColorLockRequest: Bool = false
    private var targetSubjectWidth: CGFloat? {
        // For now, use baseline width directly; can be tuned per mode later
        return baselineSubjectWidth
    }

    // MARK: - Subject lock API (UI/Watch)
    func requestSubjectLock() {
        faceTracker.shouldLockSubject = true
        print("🎯 Subject lock requested from UI/Watch.")
    }
    
    // MARK: - GPS + Vision Fusion Constants
    /// When searching: how close Vision.x must be to GPS-predicted X (0–1) to accept a person
    private let visionGpsMatchThreshold: CGFloat = 0.08     // ~8% of screen width
    /// When locked: how far Vision.x is allowed to drift from GPS before we get suspicious
    private let visionGpsDriftThreshold: CGFloat = 0.30     // ~30% of screen width
    /// How many consecutive "bad drift" frames before we drop Vision lock
    private let visionGpsDriftFrameLimit: Int = 15          // ~1.5s at 10Hz
    /// Counter for drift frames in locked state
    @State private var visionGpsDriftFrames: Int = 0
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let bottomPadding: CGFloat = isLandscape ? 16 : 90
            let sidePadding: CGFloat = isLandscape ? 50 : 16
            
                ZStack(alignment: .topTrailing) {
                // Full screen camera view - black background for any gaps
                Color.black.ignoresSafeArea()
                
                CameraView(faceTracker: faceTracker, cameraManager: cameraManager, zoomController: zoomController)
                        .ignoresSafeArea()
                    
                if showCenterDebug {
                    CenterCalibrationOverlay(currentPreset: zoomController.currentPreset)
                }
                    
                // Center line overlay
                    GeometryReader { geo in
                        let width = geo.size.width
                        let height = geo.size.height
                        let centerX = width / 2
                        
                    // Center line (yellow)
                        Path { path in
                            path.move(to: CGPoint(x: centerX, y: 0))
                            path.addLine(to: CGPoint(x: centerX, y: height))
                        }
                        .stroke(Color.yellow.opacity(0.6), lineWidth: 2)
                        
                    // GPS expected position indicator (cyan, only in GPS+AI mode)
                    if trackingMode == .gpsAI, let expX = gpsExpectedX {
                        let gpsXPos = (1 - expX) * width
                        Path { path in
                            path.move(to: CGPoint(x: gpsXPos, y: 0))
                            path.addLine(to: CGPoint(x: gpsXPos, y: height))
                        }
                        .stroke(Color.cyan.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        
                        let zoneWidth = width * 0.3
                        Rectangle()
                            .fill(Color.cyan.opacity(0.1))
                            .frame(width: zoneWidth * 2)
                            .position(x: gpsXPos, y: height / 2)
                    }
                    
                    // Detected person indicator (red dot)
                        if let face = faceTracker.faceCenter {
                            let mirroredX = 1 - face.x
                            let xPos = mirroredX * width
                            let yPos = (1 - face.y) * height
                            
                            Circle()
                                .fill(Color.red.opacity(0.8))
                                .frame(width: 18, height: 18)
                                .position(x: xPos, y: yPos)
                        }
                    }
                    .allowsHitTesting(false)
                .ignoresSafeArea()
                
                // UI Controls overlay
                VStack {
                    // Top row: Recording indicator (left) + Resolution toggle + Status (right)
                    HStack {
                        // Recording indicator
                        if cameraManager.isRecording {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text(formatDuration(cameraManager.recordingDuration))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                }
                
                        // Resolution toggle (only when not recording)
                        if !cameraManager.isRecording {
                            HStack(spacing: 6) {
                                Text(use4K ? "4K" : "1080p")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                Toggle("", isOn: $use4K)
                                    .labelsHidden()
                                    .scaleEffect(0.7)
                                    .onChange(of: use4K) { _, newValue in
                                        cameraManager.setResolution(newValue ? .uhd4K : .hd1080)
                                    }
                                
                                Text("30fps")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(6)
                        }
                        
                        Spacer()

                        // Distance debug (center-ish in top row)
                        distanceDebugLabel

                        Spacer()
                        
                        // Status display with tracking indicator
                        if trackingMode != .off {
                            HStack(spacing: 6) {
                                // Tracking active indicator (green when tracking, yellow when paused)
                                let isActive = (trackingMode == .cameraAI) || 
                                               (trackingMode == .watchGPS) || 
                                               (trackingMode == .gpsAI && isTrackingActive)
                                Circle()
                                    .fill(isActive ? Color.green : Color.yellow)
                                    .frame(width: 6, height: 6)
                                
                    if trackingMode == .cameraAI {
                                    if faceTracker.faceCenter != nil {
                                        Text("👤")
                                            .font(.caption2)
                        } else {
                                        Text("—")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                        }
                                } else if let watchLoc = gpsTracker.smoothedLocation {
                                    Text(String(format: "±%.0fm", watchLoc.horizontalAccuracy))
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                    if trackingMode == .gpsAI && faceTracker.faceCenter != nil {
                                        Text("👤")
                                            .font(.caption2)
                        }
                    } else {
                                    Text("GPS...")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.5))
                    }
                }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.top, isLandscape ? 8 : 12)
                    
                    Spacer()
                    
                    // Bottom row: Zoom + Picker + Record button
                    HStack(alignment: .bottom, spacing: 12) {
                        // Left side: Zoom controls
                        zoomButtons
                        
                        Spacer()
                        
                        VStack(spacing: 6) {
                            autoZoomButton
                            lockSubjectButton
                            subjectLockPill
                        }
                        
                        Spacer()
                        
                        // Center: Mode picker + Start button for GPS+AI
                        VStack(spacing: 8) {
                            Picker("", selection: $trackingMode) {
                        Text("Off").tag(TrackingMode.off)
                        Text("AI").tag(TrackingMode.cameraAI)
                        Text("GPS").tag(TrackingMode.watchGPS)
                                Text("AI+").tag(TrackingMode.gpsAI)
                    }
                    .pickerStyle(.segmented)
                            .frame(width: isLandscape ? 180 : 200)
                            .scaleEffect(isLandscape ? 0.9 : 1.0)
                            
                            // Start Tracking button for GPS+AI mode
                            if trackingMode == .gpsAI && calibratedBearing != nil {
                                Button(action: {
                                    isTrackingActive.toggle()
                                    if isTrackingActive {
                    restartTrackingTimer()
                                    } else {
                                        stopTrackingTimer()
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(isTrackingActive ? Color.green : Color.gray)
                                            .frame(width: 8, height: 8)
                                        Text(isTrackingActive ? "Tracking" : "Start Tracking")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isTrackingActive ? Color.green.opacity(0.3) : Color.blue.opacity(0.5))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        // Right: Record button + System panel toggle
                        VStack(alignment: .trailing, spacing: 8) {
                            // Record button
                            Button(action: {
                                if cameraManager.isRecording {
                                    cameraManager.stopRecording()
                                } else {
                                    cameraManager.startRecording()
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3)
                                        .frame(width: 56, height: 56)
                                    
                                    if cameraManager.isRecording {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.red)
                                            .frame(width: 22, height: 22)
                                    } else {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 44, height: 44)
                                    }
                                }
                }
                
                            // System panel toggle
                            Button(action: { showSystemPanel.toggle() }) {
                                Image(systemName: showSystemPanel ? "chevron.down" : "chevron.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 24)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, bottomPadding)
                    
                    // System status panel (expandable)
                    if showSystemPanel {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                VStack(alignment: .leading, spacing: 10) {
                                    // GPS Calibration section
                                    if trackingMode == .watchGPS || trackingMode == .gpsAI {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("GPS CALIBRATION")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.white.opacity(0.6))
                                            
                                            // Rig calibration button
                                            Button(action: { rigLocationManager.startRigCalibration() }) {
                                                HStack(spacing: 8) {
                                                    Text("📍")
                                                        .font(.title3)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("Rig Position")
                                                            .font(.system(size: 12, weight: .semibold))
                                                        if rigLocationManager.isCalibrating {
                                                            ProgressView(value: rigLocationManager.calibrationProgress)
                                                                .frame(width: 80)
                                                                .tint(.yellow)
                                                        Text("Samples: \(rigLocationManager.calibrationSampleCount)")
                                                            .font(.caption2)
                                                            .foregroundColor(.white.opacity(0.7))
                                                        if let err = rigLocationManager.calibrationError {
                                                            Text(err)
                                                                .font(.caption2)
                                                                .foregroundColor(.red)
                                                                .lineLimit(2)
                                                        }
                                                        } else if rigLocationManager.rigCalibratedCoord != nil {
                                                            Text("Calibrated ✓")
                                                                .font(.caption2)
                                .foregroundColor(.green)
                        } else {
                                                            Text("Tap to calibrate")
                                                                .font(.caption2)
                                .foregroundColor(.orange)
                                                        if let err = rigLocationManager.calibrationError {
                                                            Text(err)
                                                                .font(.caption2)
                                                                .foregroundColor(.red)
                                                                .lineLimit(2)
                        }
                    }
                                                    }
                                                    Spacer()
                                                }
                                                .foregroundColor(.white)
                                                .padding(10)
                                                .frame(width: 160)
                                                .background(rigLocationManager.rigCalibratedCoord != nil ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                                                .cornerRadius(8)
                                            }
                                            .disabled(rigLocationManager.isCalibrating)
                                            
                                            // Watch center status
                                            HStack(spacing: 8) {
                                                Text("🎯")
                                                    .font(.title3)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Watch Center")
                                                        .font(.system(size: 12, weight: .semibold))
                                                    if gpsTracker.watchCalibratedCoord != nil {
                                                        Text("Calibrated ✓")
                                                            .font(.caption2)
                                                            .foregroundColor(.green)
                                                    if gpsTracker.watchCalibrationSampleCount > 0 {
                                                        Text("Samples: \(gpsTracker.watchCalibrationSampleCount)")
                                                            .font(.caption2)
                                                            .foregroundColor(.white.opacity(0.7))
                }
                                                    } else {
                                                        Text("Tap on Watch")
                                                            .font(.caption2)
                                                            .foregroundColor(.orange)
                                                    if gpsTracker.watchCalibrationSampleCount > 0 {
                                                        Text("Samples: \(gpsTracker.watchCalibrationSampleCount)")
                                                            .font(.caption2)
                                                            .foregroundColor(.white.opacity(0.7))
                                                    }
                                                    }
                                                }
                                                Spacer()
                                            }
                                            .foregroundColor(.white)
                                            .padding(10)
                                            .frame(width: 160)
                                            .background(gpsTracker.watchCalibratedCoord != nil ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                                            .cornerRadius(8)
                                            
                                            // Bearing display
                                            if let brg = calibratedBearing {
                                                HStack {
                                                    Text("Bearing: \(Int(brg))°")
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundColor(.white)
                                                    Spacer()
                                                    Button(action: {
                                                        rigLocationManager.clearRigCalibration()
                                                        gpsTracker.clearWatchCalibration()
                                                        calibratedBearing = nil
                                                        isTrackingActive = false
                                                    }) {
                                                        Text("Reset")
                                                            .font(.caption2)
                                                            .foregroundColor(.red)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                            }
                                        }
                                    }
                                    
                                    // System status
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("SYSTEM STATUS")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        HStack(spacing: 12) {
                                            // Mode indicator
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(trackingMode == .off ? Color.gray : Color.green)
                                                    .frame(width: 6, height: 6)
                                                Text(trackingMode.rawValue.uppercased())
                                                    .font(.caption2)
                                            }
                                            
                                            // GPS status
                                            if trackingMode == .watchGPS || trackingMode == .gpsAI {
                                                HStack(spacing: 4) {
                                                    Circle()
                                                        .fill(gpsTracker.isReceiving ? Color.green : Color.orange)
                                                        .frame(width: 6, height: 6)
                                                    Text(gpsTracker.isReceiving ? "GPS" : "GPS...")
                                                        .font(.caption2)
                                                }
                                            }
                                            
                                            // Vision status
                                            if trackingMode == .cameraAI || trackingMode == .gpsAI {
                                                HStack(spacing: 4) {
                                                    Circle()
                                                        .fill(faceTracker.faceCenter != nil ? Color.green : Color.gray)
                                                        .frame(width: 6, height: 6)
                                                    Text(faceTracker.faceCenter != nil ? "👤" : "—")
                                                        .font(.caption2)
                                                }
                                            }
                                        }
                                        .foregroundColor(.white)
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    
                                    // Video settings
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("VIDEO")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        HStack(spacing: 8) {
                                            // Resolution buttons (synced with top toggle)
                                            Button(action: { use4K = false }) {
                                                Text("1080p")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(!use4K ? .black : .white)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(!use4K ? Color.yellow : Color.white.opacity(0.2))
                                                    .cornerRadius(6)
                                            }
                                            .disabled(cameraManager.isRecording)
                                            
                                            Button(action: { use4K = true }) {
                                                Text("4K")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(use4K ? .black : .white)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(use4K ? Color.yellow : Color.white.opacity(0.2))
                                                    .cornerRadius(6)
                                            }
                                            .disabled(cameraManager.isRecording)
                                            
                                            Spacer()
                                            
                                            // FPS display
                                            Text("30 FPS")
                                                .font(.caption2)
                                                .foregroundColor(.white.opacity(0.6))
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .padding(12)
                                .background(Color.black.opacity(0.8))
                                .cornerRadius(12)
                            }
                        }
                        .padding(.trailing, sidePadding)
                        .padding(.bottom, bottomPadding + 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: showSystemPanel)
                    }
                }
                .ignoresSafeArea(edges: .horizontal)
            }
            .onChange(of: trackingMode) { _, newMode in
                // Reset state when switching modes
                if newMode == .watchGPS || newMode == .gpsAI {
                    gpsTracker.resetSmoothing()
                }
                if newMode == .gpsAI {
                    faceTracker.useGPSGating = true
                    isTrackingActive = false  // Require manual start for GPS+AI
                    print("✅ GPS+AI mode: Waiting for calibration and start")
                } else {
                    faceTracker.useGPSGating = false
                    faceTracker.expectedX = nil
                    isTrackingActive = false
                }
                if newMode == .cameraAI {
                    faceTracker.resetTracking()
                    isTrackingActive = true  // Auto-start for pure AI mode
                    print("✅ AI mode: Vision tracking enabled")
                    restartTrackingTimer()
                } else if newMode == .watchGPS {
                    // GPS mode auto-starts
                    restartTrackingTimer()
                } else if newMode == .gpsAI {
                    faceTracker.resetTracking()
                    // Don't auto-start - wait for user to press Start Tracking
                    stopTrackingTimer()
                } else {
                    // Off mode
                    stopTrackingTimer()
                    // Reset state machine when turning off
                    trackState = .searching
                    consecutiveLockFrames = 0
                    consecutiveLostFrames = 0
                    visionGpsDriftFrames = 0
                    
                    // Optional: reset GPS quality metrics on full stop
                    gpsBias = 0.0
                    gpsErrorRMS = 0.0
                    gpsSampleCount = 0
                }
                
                // Reset tracking state machine when switching modes
                if newMode == .cameraAI || newMode == .gpsAI {
                    trackState = .searching
                    consecutiveLockFrames = 0
                    consecutiveLostFrames = 0
                    visionGpsDriftFrames = 0
                }
                
                // Reset GPS metrics when leaving GPS+AI mode
                if newMode != .gpsAI {
                    gpsBias = 0.0
                    gpsErrorRMS = 0.0
                    gpsSampleCount = 0
                    visionGpsDriftFrames = 0
                }
                }
                .onAppear {
                    // Wire subject size lock callback (set at runtime to avoid escaping self in init)
                    faceTracker.onSubjectSizeLocked = { width, height in
                        baselineSubjectWidth = width
                        baselineSubjectHeight = height
                    }
                    gpsTracker.onLockSubject = {
                        requestSubjectLock()
                    }

                    // Initialize resolution and FPS
                    cameraManager.targetFPS = 30.0
                    cameraManager.resolution = use4K ? .uhd4K : .hd1080
                    
                    // Provide rig coordinate lookup for distance sanity on center calibration
                    gpsTracker.rigCoordinateProvider = {
                        rigLocationManager.rigCalibratedCoord ?? rigLocationManager.rigLocation?.coordinate
                    }

                    // Trigger an immediate tracking tick when fresh GPS arrives
                    gpsTracker.onLocationUpdate = {
                        switch trackingMode {
                        case .watchGPS:
                            tickTracking()
                        case .gpsAI:
                            if isTrackingActive {
                                tickTracking()
                            }
                        default:
                            break
                        }
                    }
                    // Handle rig calibration arriving from Watch
                    gpsTracker.onRigCalibrationFromWatch = { coord, samples, avgAcc in
                        rigLocationManager.applyRigCalibrationFromWatch(coord: coord, samples: samples, avgAccuracy: avgAcc)
                    }
                    
                    restartTrackingTimer()
                }
                .onDisappear {
                    stopTrackingTimer()
                    gpsTracker.onLocationUpdate = nil
                    gpsTracker.rigCoordinateProvider = nil
                    gpsTracker.onRigCalibrationFromWatch = nil
                }
            .onChange(of: rigLocationManager.rigCalibratedCoord?.latitude) { _, _ in
                recomputeCalibratedBearing()
            }
            .onChange(of: gpsTracker.watchCalibratedCoord?.latitude) { _, _ in
                recomputeCalibratedBearing()
            }
        }
    }
    
    // MARK: - Timer helpers
    
    private func restartTrackingTimer() {
        stopTrackingTimer()
        
        guard trackingMode != .off else {
            print("⏸ Tracking stopped (mode: off)")
            return
        }
        
        // For GPS+AI mode, only start if isTrackingActive is true
        if trackingMode == .gpsAI && !isTrackingActive {
            print("⏸ GPS+AI mode: Waiting for Start Tracking button")
            return
        }
        
        // Start tracking timer
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            tickTracking()
        }
        
        // Run first tick immediately
        tickTracking()
        
        print("▶️ Tracking started (mode: \(trackingMode.rawValue))")
    }

    private func stopTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }
    
    // MARK: - Tracking dispatch

    private func tickTracking() {
        guard trackingMode != .off else { return }
        
        // Check if we have a vision target
        let hasVisionTarget = (faceTracker.faceCenter != nil)
        
        // Update distance + motion state (GPS pipeline)
        updateDistanceAndMotionIfPossible()
        
        // Distance-based auto zoom (no-op unless autoDistance enabled)
        zoomController.updateZoomForDistance(
            distanceMeters: viewModel.gpsDistanceMeters,
            gpsTrust: gpsTrust,
            hasGoodGPS: viewModel.gpsDistanceIsValid,
            cameraManager: cameraManager
        )
        
        // Update high-level track state (only for AI modes)
        if trackingMode == .cameraAI || trackingMode == .gpsAI {
            updateTrackState(hasVisionTarget: hasVisionTarget)
        }
        
        // Dispatch to appropriate tracking method
        switch trackingMode {
        case .off:
            return
        case .cameraAI:
            trackWithCameraAI()
        case .watchGPS:
            trackWithWatchGPS()
        case .gpsAI:
            trackWithGPSAIFusion()
        }
    }
    
    // MARK: - Tracking State Machine
    
    /// Update the tracking state based on vision detection
    private func updateTrackState(hasVisionTarget: Bool) {
        switch trackState {
        case .searching:
            if hasVisionTarget {
                consecutiveLockFrames += 1
                consecutiveLostFrames = 0
                
                if consecutiveLockFrames >= lockFramesThreshold {
                    trackState = .locked
                    print("🔒 Entering LOCKED state")
                }
            } else {
                consecutiveLockFrames = 0
                consecutiveLostFrames += 1
                // We can stay in .searching indefinitely here
            }
            
        case .locked:
            if hasVisionTarget {
                // Keep lock solid
                consecutiveLostFrames = 0
            } else {
                consecutiveLostFrames += 1
                
                if consecutiveLostFrames >= lostFramesThreshold {
                    trackState = .lost
                    consecutiveLockFrames = 0
                    print("❗️ Lost target – entering LOST state")
                }
            }
            
        case .lost:
            if hasVisionTarget {
                // Found someone again – go back to searching first
                // then quickly promote to locked if continuity is good
                trackState = .searching
                consecutiveLockFrames = 1
                consecutiveLostFrames = 0
                print("🔍 Vision reacquired – back to SEARCHING")
            } else {
                // Still lost – GPS will drive the search
                consecutiveLostFrames += 1
            }
        }
    }
    
    // MARK: - Derived GPS Trust Score (0 = trash, 1 = very reliable)
    
    /// Computed GPS trust score based on alignment between GPS predictions and Vision detections
    /// Returns 0.0 if not enough samples, otherwise 0.0-1.0 where 1.0 = perfect alignment
    private var gpsTrust: CGFloat {
        // Not enough data yet → no trust
        guard gpsSampleCount >= gpsMinSamplesForTrust else { return 0.0 }
        
        // Error component: 1 when error ≈ 0, goes toward 0 as RMS error grows
        // gpsErrorRMS is in normalized screen units [0..1] where 0.5 = half screen width
        let normalizedError = gpsErrorRMS / gpsMaxScreenErrorForTrust
        let errorComponent = max(0.0, 1.0 - normalizedError)  // clamp to [0, 1]
        
        // You can incorporate more components later (e.g., GPS accuracy, latency).
        // For now, gpsTrust == errorComponent
        return errorComponent
    }
    
    // MARK: - GPS Quality Metrics Updater
    
    /// Call this when we have BOTH a reliable Vision center and a GPS-predicted expectedX.
    /// This updates:
    ///  - gpsBias: average (gpsX - visionX)
    ///  - gpsErrorRMS: RMS error magnitude
    ///  - gpsSampleCount: number of samples
    ///
    /// NOTE: This is telemetry-only. It does NOT change any tracking behavior yet.
    private func updateGPSQualityMetrics(faceCenter: CGPoint, expectedX: CGFloat) {
        // Vision X and GPS X are both 0..1 in screen space (left→right).
        let visionX = faceCenter.x
        let gpsX = expectedX
        
        // Signed error: positive means GPS thinks target is more to the right than Vision.
        let error = gpsX - visionX
        
        // Convert to CGFloat (already is) and absolute error magnitude.
        let absError = abs(error)
        
        // Exponential moving average update for bias and RMS.
        //
        // gpsEMAAlpha controls how quickly we adapt:
        //   - small alpha (~0.05) = smoother, slower adaptation
        //   - large alpha (~0.2)  = more reactive, but noisier
        let alpha = gpsEMAAlpha
        let oneMinusAlpha = 1.0 - alpha
        
        // Update running bias (signed)
        gpsBias = oneMinusAlpha * gpsBias + alpha * error
        
        // Update running RMS error:
        // We approximate RMS with EMA of squared error, then take sqrt.
        let prevRMS = gpsErrorRMS
        let prevVarApprox = prevRMS * prevRMS
        let newVarApprox = oneMinusAlpha * prevVarApprox + alpha * (absError * absError)
        gpsErrorRMS = sqrt(newVarApprox)
        
        // Increment sample count (used to gate trust at low sample counts)
        gpsSampleCount += 1
        
        // Optional: debug log (you can comment this out later when stable)
        if gpsSampleCount % 30 == 0 { // log every ~30 samples to avoid spam
            let biasStr = String(format: "%.3f", gpsBias)
            let rmsStr  = String(format: "%.3f", gpsErrorRMS)
            let trustStr = String(format: "%.2f", gpsTrust)
            print("📡 GPS Quality – samples=\(gpsSampleCount) bias=\(biasStr) rms=\(rmsStr) trust=\(trustStr)")
        }
    }
    
    // MARK: - GPS Reliability Helper
    
    /// Returns true when GPS is fresh and aligns reasonably with Vision over time.
    private func hasGoodGPS() -> Bool {
        // Basic freshness check from your Watch tracker
        guard gpsTracker.isReceiving else { return false }
        
        // If you have gpsTrust from the telemetry section, use it:
        // (0 = trash, 1 = great; tweak 0.5–0.7 as needed)
        if gpsSampleCount >= gpsMinSamplesForTrust {
            return gpsTrust > 0.6
        }
        
        // Early in a session, before we have enough samples, just trust "freshness".
        return true
    }
    
    // MARK: - Camera AI tracking (Vision-based)
    
    private func trackWithCameraAI() {
        let hasTarget = (faceTracker.faceCenter != nil)

        if hasTarget {
            framesSinceLastTarget = 0

            // Exit recovery if we just reacquired
            if recoveryMode == .passiveHold {
                handleReacquiredAfterPassiveHold()
            }

            // Horizontal tracking (pan) and vertical framing (tilt)
            if let faceCenter = faceTracker.faceCenter {
                applyVisionFollower(from: faceCenter)
                applyTiltFollower(from: faceCenter)
            }

            // Subject width + auto zoom
            updateSubjectWidthAndAutoZoom()
            return
        } else {
            // No target this frame
            framesSinceLastTarget &+= 1
            handleNoTargetFrame()
            return
        }
    }

    private func handleReacquiredAfterPassiveHold() {
        recoveryMode = .none
        framesSinceLastTarget = 0

        // Restore auto-zoom mode if we were using it before
        if case .autoSubjectWidth = zoomModeBeforeHold {
            zoomController.mode = .autoSubjectWidth
        } else {
            zoomController.mode = zoomModeBeforeHold
        }

        print("✅ Reacquired surfer after passive hold.")
    }
    
    // MARK: - Watch GPS tracking
    
    private func trackWithWatchGPS() {
        // 1) Ensure fresh GPS
        guard gpsTracker.isReceiving else { return }

        // 2) Update distance + motion state from latest locations
        updateDistanceAndMotionIfPossible()

        // 3) Distance/speed-aware servo update toward filtered bearing
        tickGPSServoWithDistanceAndMotion()

        // (Optional) expose gpsDistanceMeters / gpsSpeedMps to UI if desired
    }
    
    // MARK: - GPS+AI Fusion Tracking
    
    private func trackWithGPSAIFusion() {
        let hasVisionTarget = (faceTracker.faceCenter != nil)
        
        switch trackState {
        case .searching:
            gpsAiSearchingTick(hasVisionTarget: hasVisionTarget)
            
        case .locked:
            gpsAiLockedTick(hasVisionTarget: hasVisionTarget)
            
        case .lost:
            gpsAiLostTick(hasVisionTarget: hasVisionTarget)
        }
    }
    
    // MARK: - GPS+AI State-Specific Tracking
    
    /// SEARCHING state: GPS drives, Vision used only when aligned with GPS
    private func gpsAiSearchingTick(hasVisionTarget: Bool) {
        // Existing fusion behavior for expectedX / gating / vision checks
        runExistingGPSAIBehavior()
        
        // Update distance + motion state from latest GPS
        updateDistanceAndMotionIfPossible()
        
        // GPS drives the rig in searching when needed
        tickGPSServoWithDistanceAndMotion()
    }
    
    /// Locked state: Vision has full control - GPS does NOT move the servo,
    /// but we watch for long-term disagreement vs GPS and can drop lock.
    private func gpsAiLockedTick(hasVisionTarget: Bool) {
        guard hasVisionTarget, let faceCenter = faceTracker.faceCenter else {
            // No vision this frame; state machine will eventually move us to .lost
            return
        }
        
        // 1) Update GPS telemetry if we have an expectedX
        if let expectedX = gpsExpectedX {
            updateGPSQualityMetrics(faceCenter: faceCenter, expectedX: expectedX)
        }

        // 2) Vision-only servo control (same as AI mode)
        applyVisionFollower(from: faceCenter)
        
        // 3) Drift fail-safe: only if GPS is considered good and we have expectedX
        guard hasGoodGPS(), let gx = gpsExpectedX else {
            visionGpsDriftFrames = 0
            return
        }
        
        let fx = faceCenter.x
        let diff = abs(fx - gx)   // 0..1 normalized screen units
        
        if diff > visionGpsDriftThreshold {
            visionGpsDriftFrames += 1
            if visionGpsDriftFrames >= visionGpsDriftFrameLimit {
                // We've been disagreeing badly for too long → drop Vision lock
                print("⚠️ GPS+AI: Vision/GPS drift too high for too long → dropping LOCKED → SEARCHING")
                trackState = .searching
                consecutiveLockFrames = 0
                consecutiveLostFrames = 0
                visionGpsDriftFrames = 0
            }
        } else {
            // Back in a reasonable band → reset drift counter
            visionGpsDriftFrames = 0
        }
    }
    
    /// LOST state: same behavior as SEARCHING (GPS tries to reacquire)
    private func gpsAiLostTick(hasVisionTarget: Bool) {
        // Existing fusion behavior for expectedX / gating / vision checks
        runExistingGPSAIBehavior()
        
        // Update distance + motion state from latest GPS
        updateDistanceAndMotionIfPossible()
        
        // GPS-driven recovery in lost state
        tickGPSServoWithDistanceAndMotion()
    }
    
    // MARK: - Helper: GPS-first behavior for SEARCHING / LOST
    
    /// In .gpsAI mode while in .searching or .lost:
    /// - If GPS is good → servo driven by GPS only
    /// - If Vision sees someone aligned with GPS → Vision takes over
    /// - If GPS is bad → fall back to Vision if available
    private func runExistingGPSAIBehavior() {
        // 1) Compute GPS-predicted expectedX in screen space (0..1) if in FOV
        let expectedX = computeExpectedXFromGPS()
        gpsExpectedX = expectedX
        faceTracker.expectedX = expectedX  // keeps your GPS-gating behavior intact
        
        let goodGPS    = hasGoodGPS()
        let hasVision  = (faceTracker.faceCenter != nil)
        
        // 2) If GPS is not usable, just fall back to Vision if we have it.
        guard goodGPS else {
            if hasVision {
                trackWithCameraAI()
            }
            return
        }
        
        // From here on, GPS is "good"
        
        // 3) If we have both GPS expectedX (in FOV) AND a Vision target:
        if let gx = expectedX, let fx = faceTracker.faceCenter?.x {
            let diff = abs(fx - gx)
            if diff < visionGpsMatchThreshold {
                // ✅ Vision + GPS agree → let Vision servo take over.
                // State machine will promote us to .locked after enough frames.
                trackWithCameraAI()
                return
            } else {
                // Vision sees someone but not aligned with GPS yet.
                // Treat GPS as the source of truth while searching.
                trackWithWatchGPS()
                return
            }
        }
        
        // 4) GPS is good but either:
        //    - no Vision target, or
        //    - GPS says outside FOV (expectedX == nil)
        // In both cases, we just use GPS-only.
        trackWithWatchGPS()
    }
    
    // MARK: - Vision Follower (Shared Logic)
    private func applyVisionFollower(from faceCenter: CGPoint) {
        let x = faceCenter.x // 0..1

        // Current zoom factor (UI space)
        let zoom = zoomController.zoomFactor
        let zoomClamped = max(1.0, min(zoom, 8.0)) // for control math

        // ---- Zoom-aware control tuning ----
        let baseGain: CGFloat = 10.0
        let baseDeadband: CGFloat = 0.02
        let baseMaxStep: CGFloat = 4.0

        // Less aggressive scaling to keep authority at high zoom
        let gainScale = 1.0 / (1.0 + 0.25 * (zoomClamped - 1.0))
        let gain = baseGain * gainScale

        let deadbandScale = 1.0 + 0.5 * (zoomClamped - 1.0) / 7.0
        let deadband: CGFloat = baseDeadband * deadbandScale

        let maxStep: CGFloat = baseMaxStep * gainScale

        let servoMirror: CGFloat = -1.0
        let baseBiasDegrees: CGFloat = centerBiasDegrees
        let lensBiasDegrees: CGFloat = zoomController.currentPreset.lensCenterBiasDegrees
        let totalBiasDegrees = baseBiasDegrees + lensBiasDegrees
        let centerBiasNorm = totalBiasDegrees / gain

        let offset = (x + centerBiasNorm) - 0.5
        print("📐 center bias preset=\(zoomController.currentPreset.displayName) base=\(baseBiasDegrees) lens=\(lensBiasDegrees) total=\(totalBiasDegrees)")

        if abs(offset) < deadband { return }

        var step = offset * gain * servoMirror
        step = max(-maxStep, min(maxStep, step))

        let currentAngle = CGFloat(api.currentPanAngle)
        let newAngle = clampAngle(currentAngle + step) // 15–165
        sendPanAngle(Int(newAngle))
    }

    // MARK: - Tilt follower (vertical framing)
    private func applyTiltFollower(from faceCenter: CGPoint) {
        let y = faceCenter.y // 0..1, top → bottom

        // Desired vertical position of surfer (slightly below center to keep more sky/horizon)
        let desiredY: CGFloat = 0.55

        let zoom = zoomController.zoomFactor
        let zoomClamped = max(1.0, min(zoom, 8.0))

        let baseGain: CGFloat = 80.0   // degrees of tilt per normalized offset
        let baseDeadband: CGFloat = 0.02
        let baseMaxStep: CGFloat = 5.0

        // Slightly reduce gain at high zoom
        let gainScale = 1.0 / (1.0 + 0.25 * (zoomClamped - 1.0))
        let gain = baseGain * gainScale
        let deadband = baseDeadband
        let maxStep = baseMaxStep * gainScale

        // Offset: positive means surfer is LOWER than desired
        let offset = y - desiredY
        if abs(offset) < deadband { return }

        var step = offset * gain

        // Limit max step
        step = max(-maxStep, min(maxStep, step))

        let currentTilt = CGFloat(api.currentTiltAngle)
        let newTilt = clampTiltAngle(currentTilt + step)

        sendTiltAngle(Int(newTilt))
    }

// MARK: - Distance + Motion Update
    private func updateDistanceAndMotionIfPossible() {
        guard
            let rigCoord = rigLocationManager.rigCalibratedCoord ?? rigLocationManager.rigLocation?.coordinate,
            let watchLocation = gpsTracker.smoothedLocation
        else {
            return
        }
        
        // 1. Compute distance from rig → watch
        let rigLoc = CLLocation(latitude: rigCoord.latitude, longitude: rigCoord.longitude)
        let distance = rigLoc.distance(from: watchLocation)   // meters
        gpsDistanceMeters = distance
        let accuracy = watchLocation.horizontalAccuracy
        let isValid = accuracy > 0 && accuracy <= 3.0 && gpsTracker.isReceiving
        viewModel.gpsDistanceMeters = distance
        viewModel.gpsDistanceIsValid = isValid
        viewModel.latestWatchAccuracy = accuracy
        
        // 2. Compute bearing rig → watch (instant)
        let bearingRW = bearing(from: rigCoord, to: watchLocation.coordinate) // uses GPSHelpers
        gpsBearingRigToWatch = bearingRW
        
        // 3. Compute speed & motion heading from last watch position
        if let prev = lastSmoothedWatchLocation {
            let dt = max(watchLocation.timestamp.timeIntervalSince(prev.timestamp), 0.1)
            let segmentDist = prev.distance(from: watchLocation) // meters
            let speed = segmentDist / dt                         // m/s
            gpsSpeedMps = speed
            
            if segmentDist > 0.5 { // ignore tiny jitter
                let motionH = bearing(from: prev.coordinate, to: watchLocation.coordinate)
                gpsMotionHeading = motionH
            }
        } else {
            gpsSpeedMps = 0
            gpsMotionHeading = nil
        }
        
        lastSmoothedWatchLocation = watchLocation
        
        // 4. Update smoothed / filtered bearing used for servo
        updateFilteredBearing(withInstantBearing: bearingRW)
    }


    // MARK: - Bearing Filtering

    /// Shortest signed angle difference (degrees) from `from` → `to`, in [-180, +180]
    private func shortestSignedAngle(from: Double, to: Double) -> Double {
        var delta = to - from
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func updateFilteredBearing(withInstantBearing instant: Double) {
        // If we don't have a previous filtered bearing, just start there.
        guard let prevFiltered = gpsFilteredBearing else {
            gpsFilteredBearing = instant
            return
        }
        
        let d = gpsDistanceMeters
        let v = gpsSpeedMps
        
        // Base smoothing factor: how much we move toward the new bearing per update.
        var alpha: Double = 0.12  // slightly slower base
        
        // Distance-dependent adjustment
        switch d {
        case ..<20:
            alpha *= 0.5  // 0.075
        case 20..<70:
            alpha *= 1.0  // 0.15
        default:
            alpha *= 1.4  // ~0.21
        }
        
        // Speed-dependent adjustment
        if v < 0.5 {           // almost still
            alpha *= 0.6
        } else if v > 3.0 {    // paddling/flying
            alpha *= 1.4
        }
        
        // Clamp alpha to a tighter range to reduce twitch
        alpha = min(max(alpha, 0.05), 0.25)
        
        // Smooth toward the instant bearing
        let deltaToInstant = shortestSignedAngle(from: prevFiltered, to: instant)
        let newBearingBase = prevFiltered + deltaToInstant * alpha
        
        // Optional: nudge toward motion heading if we have one and we're moving
        var newBearing = newBearingBase
        if let motionH = gpsMotionHeading, v > 0.8 {
            let deltaToMotion = shortestSignedAngle(from: newBearingBase, to: motionH)
            let motionInfluence: Double
            switch d {
            case ..<20:
                motionInfluence = 0.04
            case 20..<70:
                motionInfluence = 0.10
            default:
                motionInfluence = 0.14
            }
            newBearing = newBearingBase + deltaToMotion * motionInfluence
        }
        
        // Normalize to [0, 360)
        var normalized = newBearing
        while normalized < 0   { normalized += 360 }
        while normalized >= 360 { normalized -= 360 }
        
        gpsFilteredBearing = normalized
    }

    // MARK: - Distance/Speech-aware Servo Parameters

    private func servoDeadbandDegrees(forDistance d: Double) -> Double {
        switch d {
        case ..<20:
            return 2.5    // don't twitch when surfer is close
        case 20..<70:
            return 1.5
        default:
            return 1.0
        }
    }
    
    private func servoMaxStepDegrees(forDistance d: Double, speed v: Double) -> Double {
        var base: Double
        switch d {
        case ..<20:
            base = 1.5
        case 20..<70:
            base = 2.5
        default:
            base = 3.5
        }
        
        if v < 0.5 {
            base *= 0.6     // very gentle if basically still
        } else if v > 3.0 {
            base *= 1.2     // slightly more aggressive if they're moving fast
        }
        
        return min(max(base, 1.0), 6.0)
    }
    
    // MARK: - Improved GPS Servo Control
    
    /// Convert a (bearing from rig) into a "target" servo angle in [0, 180],
    /// using calibratedBearing as center mapping to 90°.
    private func servoTargetAngle(forBearing bearing: Double, calibrated center: Double) -> Double {
        var delta = bearing - center
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        
        let clamped = max(-90.0, min(90.0, delta))
        return (clamped + 90.0)
    }
    
    /// Distance + motion aware GPS servo update.
    /// Call this in watchGPS mode and GPS-driven portions of gpsAI (searching/lost).
    private func tickGPSServoWithDistanceAndMotion() {
        // GPS-driven servo path is currently disabled (archived for rework).
        // We still collect GPS distance/motion/filtered bearing, but do not move the servo here.
        return
    }

    // MARK: - Servo Control Helpers
    
    /// Clamp servo angle to valid range (15°-165° to avoid physical limits)
    private func clampAngle(_ angle: CGFloat) -> CGFloat {
        let minAngle: CGFloat = 15.0
        let maxAngle: CGFloat = 165.0
        return max(minAngle, min(maxAngle, angle))
    }
    
    /// Send servo angle command and update tracked angle
    // MARK: - PAN servo state

    /// Send pan angle command and update tracked angle
    private func sendPanAngle(_ angle: Int) {
        let raw = CGFloat(angle)
        let zoom = zoomController.zoomFactor
        
        // Stronger smoothing at high zoom (slightly relaxed for responsiveness)
        let alpha: CGFloat = zoom >= 6.0 ? 0.4 : 0.6  // 0.6 = snappier, 0.4 = smoother
        
        let smoothed: CGFloat
        if let last = lastCommandedPanAngle {
            smoothed = last + alpha * (raw - last)
        } else {
            smoothed = raw
        }
        
        lastCommandedPanAngle = smoothed
        api.trackPan(angle: Int(smoothed.rounded()))
        // Note: api.currentPanAngle is @Published and will update automatically
    }

    // MARK: - TILT servo state

    /// Clamp tilt angle to the ESP32’s allowed range (80–180)
    private func clampTiltAngle(_ angle: CGFloat) -> CGFloat {
        return max(80, min(180, angle))
    }

    /// Send tilt angle command (smoothing independent of zoom)
    private func sendTiltAngle(_ angle: Int) {
        let raw = CGFloat(angle)
        let alpha: CGFloat = 0.6 // relaxed, tilt doesn’t need zoom coupling

        let smoothed: CGFloat
        if let last = lastCommandedTiltAngle {
            smoothed = last + alpha * (raw - last)
        } else {
            smoothed = raw
        }

        let clamped = clampTiltAngle(smoothed)
        lastCommandedTiltAngle = clamped
        api.trackTilt(angle: Int(clamped.rounded()))
        // Note: api.currentTiltAngle is @Published and will update automatically
    }
    
    /// Compute where GPS says the target should appear on screen (0..1)
    /// Returns nil if target should be outside camera's field of view
    private func computeExpectedXFromGPS() -> CGFloat? {
        guard gpsTracker.isReceiving else { return nil }
        
        // Get coordinates
        let rigCoord = rigLocationManager.rigCalibratedCoord ?? rigLocationManager.rigLocation?.coordinate
        guard
            let rig = rigCoord,
            let watch = gpsTracker.smoothedLocation?.coordinate,
            let calBearing = calibratedBearing
        else { return nil }
        
        // Convert current servo angle to compass heading
        let currentHeading = servoAngleToHeading(
            servoAngle: api.currentPanAngle,
            calibratedBearing: calBearing
        )
        
        // Calculate expected X position
        return expectedXFromGPS(
            rigCoord: rig,
            watchCoord: watch,
            calibratedBearing: calBearing,
            currentCameraHeading: currentHeading
        )
    }
    
    /// Gently pan toward where GPS says the target should be
    private func panTowardExpectedX(_ expectedX: CGFloat) {
        // Expected X is 0..1 where 0.5 is center
        // We want to pan so that expectedX moves toward 0.5
        
        let offset = expectedX - 0.5  // -0.5 to +0.5
        
        // Small deadband
        if abs(offset) < 0.05 { return }
        
        // Slow movement when searching
        let gain: Double = 2.0
        let maxStep: Double = 2.0
        
        let rawStep = Double(offset) * gain
        let step = max(-maxStep, min(maxStep, rawStep))
        
        let newAngle = clampAngle(CGFloat(api.currentPanAngle) + CGFloat(step))
        sendPanAngle(Int(newAngle))
    }
    
    private func servoAngleForCurrentGPS() -> Double? {
        // Use calibrated rig position if available, otherwise fall back to live GPS
        let rigCoord = rigLocationManager.rigCalibratedCoord ?? rigLocationManager.rigLocation?.coordinate
        
        guard
            let rig = rigCoord,
            // Use smoothed location for less jittery servo movement
            let watch = gpsTracker.smoothedLocation?.coordinate,
            let forward = calibratedBearing
        else { return nil }

        let currentBearing = bearing(from: rig, to: watch) // 0..360

        // Relative angle from "forward" in range -180..+180
        var delta = forward - currentBearing
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        // Decide how wide your rig can cover, e.g. ±90°
        let maxRigSpan: Double = 90

        // Clamp delta to that span
        let clamped = max(-maxRigSpan, min(maxRigSpan, delta))

        // Map -maxSpan..+maxSpan -> 0..180
        let normalized = (clamped + maxRigSpan) / (2 * maxRigSpan)  // 0..1
        let servoAngle = normalized * 180

        return servoAngle
    }
    
    // MARK: - Calibration
    
    /// Recompute calibrated bearing when both rig and watch center are calibrated
    private func recomputeCalibratedBearing() {
        guard
            let rigCoord = rigLocationManager.rigCalibratedCoord,
            let watchCoord = gpsTracker.watchCalibratedCoord
        else {
            // Wait until both are available
            return
        }
        
        let brg = bearing(from: rigCoord, to: watchCoord)
        calibratedBearing = brg
        print("✅ Calibrated bearing = \(brg)° (rig → watch center)")
    }
    
    // MARK: - Zoom Buttons
    
    private var zoomButtons: some View {
        HStack(spacing: 8) {
            ForEach(ZoomPreset.allCases) { preset in
                Button {
                    zoomController.applyPreset(preset)
                } label: {
                    Text(preset.displayName)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            zoomController.currentPreset == preset
                            ? Color.white.opacity(0.9)
                            : Color.black.opacity(0.4)
                        )
                        .foregroundColor(
                            zoomController.currentPreset == preset
                            ? .black
                            : .white
                        )
                        .cornerRadius(12)
                }
            }
        }
    }
    
    // MARK: - Recording Helpers
    
    /// Format duration as MM:SS
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// Check if this is the current zoom level
    private func isCurrentZoom(_ zoom: Double) -> Bool {
        if case .fixed(let current) = zoomController.mode {
            return abs(current - CGFloat(zoom)) < 0.1
        }
        return abs(zoomController.zoomFactor - CGFloat(zoom)) < 0.1
    }

    // MARK: - Subject Lock UI
    private var lockSubjectButton: some View {
        Button(action: {
            requestSubjectLock()
        }) {
            Text("Lock Surfer")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.85))
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }

    private var subjectLockPill: some View {
        Group {
            if hasLockedSubject {
                Text("Subject locked ✅")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.75))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Auto Zoom Toggle
    private var autoZoomButton: some View {
        Button(action: {
            if case .autoSubjectWidth = zoomController.mode {
                zoomController.disableAutoSubjectWidth()
            } else {
                zoomController.enableAutoSubjectWidth()
            }
        }) {
            Text("Auto Zoom")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    zoomController.isAutoSubjectWidthEnabled
                    ? Color.green.opacity(0.85)
                    : Color.black.opacity(0.6)
                )
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }

    // MARK: - Distance Debug
    private var distanceDebugText: String {
        guard
            let d = viewModel.gpsDistanceMeters,
            viewModel.gpsDistanceIsValid
        else {
            return "Distance: -- m"
        }
        let feet = d * 3.28084
        return String(format: "Distance: %.0f m (%.0f ft)", d, feet)
    }

    private var distanceDebugLabel: some View {
        Text(distanceDebugText)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.6))
            .clipShape(Capsule())
            .padding(.top, 10)
    }
}

