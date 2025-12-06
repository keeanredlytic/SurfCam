/*
 * ============================================================================
 * SURFCAM - COMPLETE AI + GPS TRACKING CODE
 * ============================================================================
 * 
 * This file contains all tracking logic for the SurfCam app:
 * - Vision-based AI person detection and tracking
 * - GPS-based tracking from Apple Watch
 * - GPS+AI fusion tracking (best of both worlds)
 * - GPS calibration system (two-step: Rig + Watch Center)
 * - Servo control algorithms
 * 
 * Copy and paste this entire file as needed.
 * All code is production-ready and tested.
 * 
 * ============================================================================
 */

import Foundation
import Vision
import CoreMedia
import CoreLocation
import WatchConnectivity
import ImageIO
import UIKit
import Combine

// ============================================================================
// MARK: - GPS Helper Functions
// ============================================================================

/// Compute bearing from one coordinate to another
/// Returns bearing in degrees (0..360), where 0 = North, 90 = East, etc.
func bearing(from: CLLocationCoordinate2D,
             to: CLLocationCoordinate2D) -> Double {
    let lat1 = from.latitude * .pi / 180
    let lon1 = from.longitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let lon2 = to.longitude * .pi / 180

    let dLon = lon2 - lon1

    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    var bearing = atan2(y, x) * 180 / .pi  // -180..+180
    if bearing < 0 { bearing += 360 }      // 0..360
    return bearing
}

/// Average multiple GPS samples using accuracy-weighted mean
/// Better accuracy samples get more weight (1/σ² weighting)
func averagedCoordinate(from locations: [CLLocation]) -> CLLocationCoordinate2D? {
    guard !locations.isEmpty else { return nil }
    
    var sumLat = 0.0
    var sumLon = 0.0
    var totalWeight = 0.0
    
    for loc in locations {
        var acc = loc.horizontalAccuracy
        // Skip invalid accuracy values
        if acc <= 0 || acc.isNaN { continue }
        // Don't let accuracy be < 3m (prevents single point from dominating)
        acc = max(acc, 3.0)
        // 1/σ² weighting - better accuracy = higher weight
        let weight = 1.0 / (acc * acc)
        
        sumLat += loc.coordinate.latitude * weight
        sumLon += loc.coordinate.longitude * weight
        totalWeight += weight
    }
    
    guard totalWeight > 0 else { return nil }
    
    return CLLocationCoordinate2D(
        latitude: sumLat / totalWeight,
        longitude: sumLon / totalWeight
    )
}

/// Horizontal field of view in degrees - adjust per camera lens
/// ~60° for wide angle, ~40° for telephoto
let cameraHFOV: Double = 60

/// Calculate expected screen X position (0..1) based on GPS data
/// Returns nil if the target should be outside the camera's field of view
func expectedXFromGPS(
    rigCoord: CLLocationCoordinate2D,
    watchCoord: CLLocationCoordinate2D,
    calibratedBearing: Double,
    currentCameraHeading: Double
) -> CGFloat? {
    // 1. Where is the watch from the rig, in absolute bearing?
    let brg = bearing(from: rigCoord, to: watchCoord)  // 0..360
    
    // 2. Angle from camera's forward direction to surfer
    var delta = brg - currentCameraHeading
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    
    // 3. If surfer is way outside camera FOV, bail out
    if abs(delta) > cameraHFOV / 2 {
        return nil  // They should be off-screen
    }
    
    // 4. Map delta [-HFOV/2, +HFOV/2] to screen x [0, 1]
    let normalized = (delta + cameraHFOV / 2) / cameraHFOV  // 0..1
    return CGFloat(max(0, min(1, normalized)))
}

/// Convert servo angle (0-180) to compass heading based on calibrated bearing
/// Assumes servo 90° = calibrated center bearing
func servoAngleToHeading(servoAngle: Double, calibratedBearing: Double) -> Double {
    // Servo 90° = center = calibratedBearing
    // Servo 0° = calibratedBearing - 90°
    // Servo 180° = calibratedBearing + 90°
    let offset = servoAngle - 90  // -90 to +90
    var heading = calibratedBearing + offset
    if heading < 0 { heading += 360 }
    if heading >= 360 { heading -= 360 }
    return heading
}

// ============================================================================
// MARK: - Person Detection Data Structure
// ============================================================================

/// Represents a detected person with scoring information
struct PersonDetection: Identifiable {
    let id: UUID
    let x: CGFloat           // center x, normalized 0..1
    let y: CGFloat           // center y, normalized 0..1
    let width: CGFloat       // normalized width
    let height: CGFloat      // normalized height
    let confidence: Float
    
    var area: CGFloat { width * height }
}

// ============================================================================
// MARK: - FaceTracker (Vision-based AI Tracking)
// ============================================================================

class FaceTracker: ObservableObject {
    // Normalized 0–1 coords of the tracked target (body center)
    @Published var faceCenter: CGPoint? = nil
    
    // All detected people this frame (for GPS-gated selection)
    @Published var allDetections: [PersonDetection] = []
    
    // Currently tracked person ID (for continuity scoring)
    @Published var currentTargetID: UUID?

    private let visionQueue = DispatchQueue(label: "FaceTracker.visionQueue")
    private var smoothedCenter: CGPoint? = nil
    
    // Cached orientation updated from main thread
    private var cachedOrientation: CGImagePropertyOrientation = .right
    
    // GPS gating support
    var expectedX: CGFloat?  // Set externally by tracking controller
    var useGPSGating = false

    private var frameCount = 0

    /// Call this from the main thread to update the cached orientation
    func updateOrientation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOrientation()
            }
            return
        }
        
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        let interfaceOrientation = scene?.interfaceOrientation ?? .portrait

        switch interfaceOrientation {
        case .portrait:
            cachedOrientation = .right
        case .portraitUpsideDown:
            cachedOrientation = .left
        case .landscapeLeft:
            cachedOrientation = .down
        case .landscapeRight:
            cachedOrientation = .up
        default:
            cachedOrientation = .right
        }
    }
    
    /// Reset tracking state (call when switching modes)
    func resetTracking() {
        smoothedCenter = nil
        faceCenter = nil
        currentTargetID = nil
        allDetections = []
    }

    /// Process a camera frame for person detection
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Debug: confirm frames are being received (every 30 frames to avoid spam)
        frameCount += 1
        if frameCount % 30 == 0 {
            print("🟢 Vision processing frame \(frameCount)")
        }

        let exifOrientation = cachedOrientation
        let gpsExpectedX = expectedX
        let gpsGating = useGPSGating

        let request = VNDetectHumanRectanglesRequest { [weak self] request, _ in
            guard let self = self else { return }

            guard let results = request.results as? [VNHumanObservation] else {
                DispatchQueue.main.async {
                    self.faceCenter = nil
                    self.smoothedCenter = nil
                    self.allDetections = []
                }
                return
            }

            // Filter by confidence so we ignore super-weak blobs
            let minConfidence: VNConfidence = 0.5
            let candidates = results.filter { $0.confidence >= minConfidence }
            
            // Convert to PersonDetection structs
            let detections = candidates.map { obs -> PersonDetection in
                PersonDetection(
                    id: UUID(),  // New ID each frame (we use position for continuity)
                    x: obs.boundingBox.midX,
                    y: obs.boundingBox.midY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height,
                    confidence: obs.confidence
                )
            }
            
            guard !detections.isEmpty else {
                DispatchQueue.main.async {
                    self.faceCenter = nil
                    self.smoothedCenter = nil
                    self.allDetections = []
                    // Don't clear currentTargetID - keep it for when they reappear
                }
                return
            }

            // Choose best detection using scoring
            let previous = self.smoothedCenter
            let chosen: PersonDetection
            
            if gpsGating, let expX = gpsExpectedX {
                // GPS-gated selection: score each person
                chosen = self.pickBestTarget(
                    candidates: detections,
                    expectedX: expX,
                    previousCenter: previous
                )
            } else if let prev = previous {
                // No GPS: use position continuity
                chosen = detections.min(by: { a, b in
                    let da = hypot(a.x - prev.x, a.y - prev.y)
                    let db = hypot(b.x - prev.x, b.y - prev.y)
                    return da < db
                })!
            } else {
                // First frame: just pick the largest box
                chosen = detections.max(by: { $0.area < $1.area })!
            }

            let rawCenter = CGPoint(x: chosen.x, y: chosen.y)

            // Low-pass filter to smooth jitter
            let alpha: CGFloat = 0.3   // 0 = very smooth, 1 = no smoothing
            let newCenter: CGPoint
            if let prev = self.smoothedCenter {
                newCenter = CGPoint(
                    x: prev.x * (1 - alpha) + rawCenter.x * alpha,
                    y: prev.y * (1 - alpha) + rawCenter.y * alpha
                )
            } else {
                newCenter = rawCenter
            }

            DispatchQueue.main.async {
                self.smoothedCenter = newCenter
                self.faceCenter = newCenter
                self.allDetections = detections
            }
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: exifOrientation,
            options: [:]
        )

        visionQueue.async {
            try? handler.perform([request])
        }
    }
    
    // MARK: - GPS-Gated Person Selection
    
    /// Score a person based on GPS proximity, continuity, and size
    private func scorePerson(
        _ person: PersonDetection,
        expectedX: CGFloat,
        previousCenter: CGPoint?
    ) -> Double {
        // GPS proximity score (0..1)
        var gpsScore = 0.0
        let dx = abs(person.x - expectedX)
        // If they're within 30% of screen width from where GPS says:
        if dx < 0.3 {
            gpsScore = 1.0 - Double(dx / 0.3)  // 1 at exact, 0 at edge
        }
        
        // Continuity score: prefer whoever we were tracking last time
        var continuityScore = 0.0
        if let prev = previousCenter {
            let dist = hypot(person.x - prev.x, person.y - prev.y)
            // If within 20% of screen from previous position, give continuity bonus
            if dist < 0.2 {
                continuityScore = 1.0 - Double(dist / 0.2)
            }
        }
        
        // Size score: favor closer (larger) people
        let sizeScore = min(1.0, Double(person.area / 0.1))  // Normalize by ~10% screen area
        
        // Weighted sum - GPS is most important when available
        return 0.50 * gpsScore +
               0.35 * continuityScore +
               0.15 * sizeScore
    }
    
    /// Pick the best target from candidates using GPS gating
    private func pickBestTarget(
        candidates: [PersonDetection],
        expectedX: CGFloat,
        previousCenter: CGPoint?
    ) -> PersonDetection {
        guard !candidates.isEmpty else {
            fatalError("pickBestTarget called with empty candidates")
        }
        
        return candidates.max { a, b in
            scorePerson(a, expectedX: expectedX, previousCenter: previousCenter)
            <
            scorePerson(b, expectedX: expectedX, previousCenter: previousCenter)
        }!
    }
}

// ============================================================================
// MARK: - RigLocationManager (Rig GPS Position)
// ============================================================================

class RigLocationManager: NSObject, ObservableObject {
    // Current GPS location (live)
    @Published var rigLocation: CLLocation?
    
    // Calibrated rig position (averaged over multiple samples)
    @Published var rigCalibratedCoord: CLLocationCoordinate2D?
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0  // 0..1
    @Published var calibrationSampleCount = 0
    
    private let manager = CLLocationManager()
    
    // Calibration state
    private var rigSamples: [CLLocation] = []
    private var rigCalTimer: Timer?
    private var calibrationStartTime: Date?
    private let calibrationDuration: TimeInterval = 7.0  // 7 seconds
    private let sampleInterval: TimeInterval = 0.3  // Sample every 0.3s
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    // MARK: - Rig Calibration
    
    /// Start calibrating the rig position (call while standing at/near tripod)
    func startRigCalibration() {
        rigSamples.removeAll()
        rigCalTimer?.invalidate()
        calibrationStartTime = Date()
        isCalibrating = true
        calibrationProgress = 0
        calibrationSampleCount = 0
        
        // Ensure we're getting high-accuracy GPS
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        
        rigCalTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            
            let elapsed = Date().timeIntervalSince(self.calibrationStartTime ?? Date())
            self.calibrationProgress = min(elapsed / self.calibrationDuration, 1.0)
            
            // Check if calibration window is complete
            if elapsed >= self.calibrationDuration {
                timer.invalidate()
                self.finishRigCalibration()
                return
            }
            
            // Sample current location
            guard let loc = self.rigLocation else { return }
            
            // Filter: reject bad accuracy
            if loc.horizontalAccuracy <= 0 || loc.horizontalAccuracy > 20 {
                return
            }
            
            // Filter: reject stale timestamps
            if abs(loc.timestamp.timeIntervalSinceNow) > 3 {
                return
            }
            
            self.rigSamples.append(loc)
            self.calibrationSampleCount = self.rigSamples.count
        }
    }
    
    /// Cancel ongoing rig calibration
    func cancelRigCalibration() {
        rigCalTimer?.invalidate()
        rigCalTimer = nil
        isCalibrating = false
        calibrationProgress = 0
        rigSamples.removeAll()
    }
    
    private func finishRigCalibration() {
        isCalibrating = false
        calibrationProgress = 1.0
        rigCalTimer = nil
        
        guard let avgCoord = averagedCoordinate(from: rigSamples) else {
            print("❌ Rig calibration failed: not enough good samples (\(rigSamples.count))")
            return
        }
        
        rigCalibratedCoord = avgCoord
        print("✅ Rig calibrated at \(avgCoord.latitude), \(avgCoord.longitude) from \(rigSamples.count) samples")
    }
    
    /// Clear the calibrated rig position
    func clearRigCalibration() {
        rigCalibratedCoord = nil
    }
}

extension RigLocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            rigLocation = loc
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Rig location error: \(error.localizedDescription)")
    }
}

// ============================================================================
// MARK: - WatchGPSTracker (Watch GPS Stream)
// ============================================================================

class WatchGPSTracker: NSObject, ObservableObject, WCSessionDelegate {
    // Published location data
    @Published var lastWatchLocation: CLLocation?
    @Published var smoothedLocation: CLLocation?  // Smoothed for servo control
    @Published var isReceiving = false  // True if receiving recent updates
    @Published var updateRate: Double = 0  // Updates per second from Watch
    @Published var latency: TimeInterval = 0  // Time since last update
    
    // Watch center calibration (received from watch)
    @Published var watchCalibratedCoord: CLLocationCoordinate2D?
    @Published var watchCalibrationSampleCount: Int = 0
    
    // Smoothing parameters
    private let smoothingAlpha: Double = 0.4  // 0 = very smooth, 1 = no smoothing
    private var smoothedLat: Double?
    private var smoothedLon: Double?
    
    // Staleness detection
    private let maxStaleAge: TimeInterval = 2.0  // Consider stale after 2 seconds
    private var lastUpdateTime: Date = .distantPast
    private var stalenessTimer: Timer?
    
    // Stats
    private var updateCount = 0
    private var statsResetTime = Date()

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        
        // Start staleness checker
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkStaleness()
        }
    }
    
    deinit {
        stalenessTimer?.invalidate()
    }
    
    private func checkStaleness() {
        let timeSinceUpdate = Date().timeIntervalSince(lastUpdateTime)
        DispatchQueue.main.async {
            self.latency = timeSinceUpdate
            self.isReceiving = timeSinceUpdate < self.maxStaleAge
        }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any]) {
        
        // Handle center calibration message from watch
        if let calibration = message["centerCalibration"] as? [String: Any],
           let lat = calibration["lat"] as? CLLocationDegrees,
           let lon = calibration["lon"] as? CLLocationDegrees,
           let sampleCount = calibration["samples"] as? Int {
            
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            DispatchQueue.main.async {
                self.watchCalibratedCoord = coord
                self.watchCalibrationSampleCount = sampleCount
                print("✅ Received watch center calibration: \(lat), \(lon) from \(sampleCount) samples")
            }
            return
        }
        
        // Handle location updates
        guard let list = message["locations"] as? [[String: Any]],
              let last = list.last,
              let lat = last["lat"] as? CLLocationDegrees,
              let lon = last["lon"] as? CLLocationDegrees,
              let ts = last["ts"] as? TimeInterval else { return }
        
        let accuracy = last["acc"] as? CLLocationAccuracy ?? 10
        
        // Update stats
        updateCount += 1
        let elapsed = Date().timeIntervalSince(statsResetTime)
        if elapsed > 1.0 {
            let rate = Double(updateCount) / elapsed
            DispatchQueue.main.async {
                self.updateRate = rate
            }
            updateCount = 0
            statsResetTime = Date()
        }
        
        // Create raw location
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let rawLoc = CLLocation(
            coordinate: coord,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: ts)
        )
        
        // Apply exponential smoothing to reduce jitter
        let smoothedCoord: CLLocationCoordinate2D
        if let prevLat = smoothedLat, let prevLon = smoothedLon {
            let newLat = prevLat * (1 - smoothingAlpha) + lat * smoothingAlpha
            let newLon = prevLon * (1 - smoothingAlpha) + lon * smoothingAlpha
            smoothedLat = newLat
            smoothedLon = newLon
            smoothedCoord = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
        } else {
            // First point - no smoothing
            smoothedLat = lat
            smoothedLon = lon
            smoothedCoord = coord
        }
        
        let smoothedLoc = CLLocation(
            coordinate: smoothedCoord,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: ts)
        )
        
        lastUpdateTime = Date()
        
        DispatchQueue.main.async {
            self.lastWatchLocation = rawLoc
            self.smoothedLocation = smoothedLoc
            self.isReceiving = true
            self.latency = 0
        }
    }
    
    // Reset smoothing (call when starting new tracking session)
    func resetSmoothing() {
        smoothedLat = nil
        smoothedLon = nil
        smoothedLocation = nil
    }
    
    // Clear watch center calibration
    func clearWatchCalibration() {
        watchCalibratedCoord = nil
        watchCalibrationSampleCount = 0
    }

    // Required stubs
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession activation error: \(error.localizedDescription)")
        } else {
            print("WCSession activated: \(activationState.rawValue)")
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

// ============================================================================
// MARK: - Tracking Controller (Main Tracking Logic)
// ============================================================================

/*
 * This section contains the main tracking dispatch logic.
 * In your actual app, this would be part of CameraScreen.swift
 * 
 * Key methods:
 * - trackWithCameraAI() - Pure Vision-based tracking
 * - trackWithWatchGPS() - Pure GPS-based tracking
 * - trackWithGPSAIFusion() - GPS+AI fusion tracking
 * - servoAngleForCurrentGPS() - Convert GPS to servo angle
 */

// MARK: - AI Tracking (Vision-based)

/*
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
*/

// MARK: - GPS Tracking

/*
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
*/

// MARK: - GPS+AI Fusion Tracking

/*
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

/// Convert GPS location to servo angle (0-180)
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

/// Recompute calibrated bearing when both calibrations are complete
private func recomputeCalibratedBearing() {
    guard let rigCoord = rigLocationManager.rigCalibratedCoord,
          let watchCoord = gpsTracker.watchCalibratedCoord else {
        calibratedBearing = nil
        return
    }
    
    let brg = bearing(from: rigCoord, to: watchCoord)
    calibratedBearing = brg
    print("✅ Calibrated bearing = \(brg)° (rig -> watch center)")
}
*/

// ============================================================================
// MARK: - Configuration Parameters Summary
// ============================================================================

/*
 * TRACKING PARAMETERS:
 * - Tracking tick interval: 0.1s (10 Hz)
 * - AI deadband: 10%
 * - AI gain: 8
 * - AI max step: 4°
 * - Vision smoothing alpha: 0.3
 * - Vision min confidence: 0.5
 * 
 * GPS PARAMETERS:
 * - GPS smoothing alpha: 0.4
 * - Max stale age: 2s
 * - GPS max step (close): 3°
 * - GPS max step (medium): 5°
 * - GPS max step (far): 8°
 * - GPS deadband: 0.5°
 * 
 * CALIBRATION PARAMETERS:
 * - Calibration duration: 7s
 * - Sample interval: 0.3s
 * - Max accuracy: 20m
 * - Max age: 3s
 * - Min accuracy clamp: 3m
 * 
 * GPS+AI FUSION PARAMETERS:
 * - GPS score weight: 50%
 * - Continuity weight: 35%
 * - Size weight: 15%
 * - GPS gate threshold: 30%
 * - Continuity threshold: 20%
 * - Camera HFOV: 60°
 */

// ============================================================================
// END OF TRACKING CODE
// ============================================================================

