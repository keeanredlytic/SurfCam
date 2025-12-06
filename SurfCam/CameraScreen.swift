import SwiftUI
import CoreLocation

enum TrackingMode: String, CaseIterable {
    case off
    case cameraAI
    case watchGPS
    case gpsAI      // GPS+AI fusion - best of both worlds
}

struct CameraScreen: View {
    @ObservedObject var api: PanRigAPI
    @ObservedObject var faceTracker: FaceTracker
    @ObservedObject var rigLocationManager: RigLocationManager
    @ObservedObject var gpsTracker: WatchGPSTracker
    @ObservedObject var zoomController: ZoomController
    @ObservedObject var cameraManager: CameraSessionManager

    @State private var trackingMode: TrackingMode = .off
    @State private var trackingTimer: Timer? = nil
    @State private var calibratedBearing: Double? = nil
    @State private var gpsExpectedX: CGFloat? = nil  // Where GPS says target should be on screen
    @State private var isTrackingActive = false  // For GPS+AI mode - requires manual start
    @State private var showSystemPanel = false  // Toggle for system status panel
    @State private var use4K: Bool = false  // Resolution toggle: false = 1080p, true = 4K
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let bottomPadding: CGFloat = isLandscape ? 16 : 90
            let sidePadding: CGFloat = isLandscape ? 50 : 16
            
                ZStack {
                // Full screen camera view - black background for any gaps
                Color.black.ignoresSafeArea()
                
                CameraView(faceTracker: faceTracker, cameraManager: cameraManager, zoomController: zoomController)
                        .ignoresSafeArea()
                    
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
                        HStack(spacing: 3) {
                            ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { zoom in
                                Button(action: {
                                    zoomController.mode = .fixed(CGFloat(zoom))
                                    zoomController.setZoomLevel(CGFloat(zoom))
                                }) {
                                    Text(zoom == 1.0 ? "1x" : String(format: "%.0fx", zoom))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(isCurrentZoom(zoom) ? .black : .white)
                                        .frame(width: 32, height: 28)
                                        .background(isCurrentZoom(zoom) ? Color.yellow : Color.black.opacity(0.5))
                                        .cornerRadius(6)
                                }
                            }
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
                                                        } else if rigLocationManager.rigCalibratedCoord != nil {
                                                            Text("Calibrated ✓")
                                                                .font(.caption2)
                                                                .foregroundColor(.green)
                                                        } else {
                                                            Text("Tap to calibrate")
                                                                .font(.caption2)
                                                                .foregroundColor(.orange)
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
                                                    } else {
                                                        Text("Tap on Watch")
                                                            .font(.caption2)
                                                            .foregroundColor(.orange)
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
                }
                }
                .onAppear {
                    // Initialize resolution and FPS
                    cameraManager.targetFPS = 30.0
                    cameraManager.resolution = use4K ? .uhd4K : .hd1080
                    
                    restartTrackingTimer()
                }
                .onDisappear {
                    stopTrackingTimer()
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
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
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
    
    // MARK: - Camera AI tracking (Vision-based)
    
    private func trackWithCameraAI() {
        guard let face = faceTracker.faceCenter else { return }

        // use mirroredX for flipped preview
        let mirroredX = 1 - face.x
        let offset = (mirroredX - 0.5) * 2.0   // -1..+1

        let deadband: CGFloat = 0.10
        if abs(offset) < deadband { return }

        let gain: Double = 8
        let maxStep: Double = 4

        // Fixed: Removed negative sign - face on left (offset < 0) should move servo left (decrease angle)
        let rawStep = Double(offset) * gain
        let step = max(-maxStep, min(maxStep, rawStep))

        let newAngle = max(0, min(180, api.currentAngle + step))
        api.track(angle: Int(newAngle))
    }
    
    // MARK: - Watch GPS tracking
    
    private func trackWithWatchGPS() {
        // Don't track if GPS data is stale
        guard gpsTracker.isReceiving else { return }
        
        guard let targetAngle = servoAngleForCurrentGPS() else { return }

        // Smooth servo movement to prevent jerking
        let current = api.currentAngle
        let diff = targetAngle - current
        
        // Adaptive step size based on distance
        // Larger steps for bigger differences, smaller steps for fine-tuning
        let maxStepPerTick: Double
        if abs(diff) > 30 {
            maxStepPerTick = 8  // Fast catch-up for large movements
        } else if abs(diff) > 10 {
            maxStepPerTick = 5  // Medium speed
        } else {
            maxStepPerTick = 3  // Slow for precision
        }

        // Ignore very tiny differences (deadband)
        if abs(diff) < 0.5 { return }

        let step = max(-maxStepPerTick, min(maxStepPerTick, diff))
        let newAngle = current + step

        api.track(angle: Int(newAngle))
    }
    
    // MARK: - GPS+AI Fusion Tracking
    
    private func trackWithGPSAIFusion() {
        // Step 1: Compute expected screen X from GPS
        let expectedX = computeExpectedXFromGPS()
        gpsExpectedX = expectedX
        faceTracker.expectedX = expectedX
        
        // Step 2: Check if Vision found a target
        let hasVisionTarget = faceTracker.faceCenter != nil
        
        if let expX = expectedX {
            // GPS says target should be in FOV
            
            if hasVisionTarget {
                // ✅ Vision found someone - track with AI (GPS-gated selection already applied)
                trackWithCameraAI()
            } else {
                // ⚠️ GPS says in-frame but Vision can't see them
                // Gently pan toward where GPS says they should be
                panTowardExpectedX(expX)
            }
        } else {
            // GPS says target is outside FOV
            // Use pure GPS tracking to rotate toward them
            if gpsTracker.isReceiving {
                trackWithWatchGPS()
            }
        }
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
            servoAngle: api.currentAngle,
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
        
        let newAngle = max(0, min(180, api.currentAngle + step))
        api.track(angle: Int(newAngle))
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
        var delta = currentBearing - forward
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
}

