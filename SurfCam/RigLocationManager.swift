import CoreLocation
import Combine

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

