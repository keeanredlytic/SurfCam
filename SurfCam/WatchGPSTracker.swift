import WatchConnectivity
import CoreLocation

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

