import CoreLocation
import WatchConnectivity
import HealthKit

class WatchLocationManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    @Published var currentLocation: CLLocation?
    @Published var isTracking = false
    @Published var accuracy: Double = -1  // Current GPS accuracy in meters
    @Published var updateRate: Double = 0  // Updates per second
    
    // Center calibration state
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0  // 0..1
    @Published var calibrationSampleCount = 0
    @Published var lastCalibrationResult: String?  // Status message
    
    private let manager = CLLocationManager()
    private let session = WCSession.default
    
    // HealthKit workout session to keep GPS alive and frequent
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    
    // Rate limiting and filtering
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 0.2  // ~5 Hz max (matches servo loop)
    private let maxAccuracy: Double = 15.0  // Reject points worse than 15m
    private let maxAge: TimeInterval = 3.0  // Reject points older than 3 seconds
    
    // Center calibration
    private var calibrationSamples: [CLLocation] = []
    private var calibrationTimer: Timer?
    private var calibrationStartTime: Date?
    private let calibrationDuration: TimeInterval = 7.0  // 7 seconds
    private let calibrationSampleInterval: TimeInterval = 0.3  // Sample every 0.3s
    
    // Stats tracking
    private var updateCount = 0
    private var lastStatsReset = Date()

    override init() {
        super.init()
        
        // Set up location manager with best settings for outdoor tracking
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation  // Best for outdoor GPS
        manager.activityType = .fitness  // Optimize for fitness/outdoor activity
        manager.distanceFilter = kCLDistanceFilterNone  // Don't rate limit by distance
        // Note: pausesLocationUpdatesAutomatically and allowsBackgroundLocationUpdates
        // are iOS-only. On watchOS, the workout session keeps GPS active.
        
        // Initialize WatchConnectivity
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if WCSession.isSupported() {
                self.session.delegate = self
                self.session.activate()
            }
        }
        
        // Request authorization
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.requestAuthorizationIfNeeded()
        }
    }
    
    private func requestAuthorizationIfNeeded() {
        let locationStatus = manager.authorizationStatus
        if locationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        
        // Request HealthKit authorization for workout sessions
        if HKHealthStore.isHealthDataAvailable() {
            let types: Set<HKSampleType> = [HKWorkoutType.workoutType()]
            healthStore.requestAuthorization(toShare: types, read: types) { success, error in
                if let error = error {
                    print("HealthKit auth error: \(error.localizedDescription)")
                }
            }
        }
    }

    func start() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            requestAuthorizationIfNeeded()
            return
        }
        
        // Start workout session to keep GPS alive and frequent
        startWorkoutSession()
        
        // Start location updates
        manager.startUpdatingLocation()
        isTracking = true
        
        // Reset stats
        updateCount = 0
        lastStatsReset = Date()
    }

    func stop() {
        manager.stopUpdatingLocation()
        stopWorkoutSession()
        isTracking = false
    }
    
    // MARK: - Center Calibration
    
    /// Start center calibration (call while standing where "center" should be)
    func startCenterCalibration() {
        calibrationSamples.removeAll()
        calibrationTimer?.invalidate()
        calibrationStartTime = Date()
        isCalibrating = true
        calibrationProgress = 0
        calibrationSampleCount = 0
        lastCalibrationResult = nil
        
        // Ensure we're getting location updates
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            requestAuthorizationIfNeeded()
        }
        
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: calibrationSampleInterval, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            
            let elapsed = Date().timeIntervalSince(self.calibrationStartTime ?? Date())
            
            DispatchQueue.main.async {
                self.calibrationProgress = min(elapsed / self.calibrationDuration, 1.0)
            }
            
            // Check if calibration window is complete
            if elapsed >= self.calibrationDuration {
                timer.invalidate()
                self.finishCenterCalibration()
                return
            }
            
            // Sample current location
            guard let loc = self.currentLocation else { return }
            
            // Filter: reject bad accuracy
            if loc.horizontalAccuracy <= 0 || loc.horizontalAccuracy > 20 {
                return
            }
            
            // Filter: reject stale timestamps
            if abs(loc.timestamp.timeIntervalSinceNow) > 3 {
                return
            }
            
            self.calibrationSamples.append(loc)
            DispatchQueue.main.async {
                self.calibrationSampleCount = self.calibrationSamples.count
            }
        }
    }
    
    /// Cancel ongoing calibration
    func cancelCenterCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        isCalibrating = false
        calibrationProgress = 0
        calibrationSamples.removeAll()
    }
    
    private func finishCenterCalibration() {
        calibrationTimer = nil
        
        DispatchQueue.main.async {
            self.isCalibrating = false
            self.calibrationProgress = 1.0
        }
        
        guard let avgCoord = averagedCoordinate(from: calibrationSamples) else {
            DispatchQueue.main.async {
                self.lastCalibrationResult = "❌ Failed"
            }
            print("❌ Center calibration failed: not enough good samples (\(calibrationSamples.count))")
            return
        }
        
        // Send calibration to phone via WatchConnectivity
        sendCalibrationToPhone(avgCoord, sampleCount: calibrationSamples.count)
        
        DispatchQueue.main.async {
            self.lastCalibrationResult = "✅ Sent"
        }
        print("✅ Center calibrated at \(avgCoord.latitude), \(avgCoord.longitude) from \(calibrationSamples.count) samples")
    }
    
    private func sendCalibrationToPhone(_ coord: CLLocationCoordinate2D, sampleCount: Int) {
        guard WCSession.isSupported(), session.isReachable else {
            DispatchQueue.main.async {
                self.lastCalibrationResult = "⚠️ Phone not reachable"
            }
            return
        }
        
        let payload: [String: Any] = [
            "centerCalibration": [
                "lat": coord.latitude,
                "lon": coord.longitude,
                "samples": sampleCount
            ]
        ]
        
        session.sendMessage(payload, replyHandler: nil) { [weak self] error in
            print("Failed to send calibration: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self?.lastCalibrationResult = "❌ Send failed"
            }
        }
    }
    
    // MARK: - Workout Session (keeps GPS alive)
    
    private func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        
        let config = HKWorkoutConfiguration()
        config.activityType = .walking  // Good for outdoor GPS tracking
        config.locationType = .outdoor
        
        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workoutBuilder = workoutSession?.associatedWorkoutBuilder()
            workoutBuilder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            
            workoutSession?.startActivity(with: Date())
            workoutBuilder?.beginCollection(withStart: Date()) { success, error in
                if let error = error {
                    print("Workout collection error: \(error.localizedDescription)")
                }
            }
            print("Workout session started - GPS will stay active")
        } catch {
            print("Failed to start workout session: \(error.localizedDescription)")
        }
    }
    
    private func stopWorkoutSession() {
        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: Date()) { success, error in
            if let error = error {
                print("Workout end error: \(error.localizedDescription)")
            }
        }
        workoutSession = nil
        workoutBuilder = nil
    }
    
    // MARK: - Location Updates

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        
        // Update stats
        updateCount += 1
        let elapsed = Date().timeIntervalSince(lastStatsReset)
        if elapsed > 1.0 {
            DispatchQueue.main.async {
                self.updateRate = Double(self.updateCount) / elapsed
            }
            updateCount = 0
            lastStatsReset = Date()
        }
        
        // Always update local display
        DispatchQueue.main.async {
            self.currentLocation = loc
            self.accuracy = loc.horizontalAccuracy
        }
        
        // --- FILTERING: Only send good, fresh points ---
        
        // 1) Reject invalid accuracy (negative means invalid)
        if loc.horizontalAccuracy < 0 {
            return
        }
        
        // 2) Reject poor accuracy (> 15 meters)
        if loc.horizontalAccuracy > maxAccuracy {
            print("Skipping low accuracy point: \(loc.horizontalAccuracy)m")
            return
        }
        
        // 3) Reject stale timestamps (> 3 seconds old)
        if abs(loc.timestamp.timeIntervalSinceNow) > maxAge {
            print("Skipping stale point: \(abs(loc.timestamp.timeIntervalSinceNow))s old")
            return
        }
        
        // 4) Rate limit sends (~5 Hz max)
        let now = Date()
        if now.timeIntervalSince(lastSentAt) < minSendInterval {
            return
        }
        lastSentAt = now
        
        // --- SEND: Good point passes all filters ---
        sendLocationToPhone(loc)
    }
    
    private func sendLocationToPhone(_ loc: CLLocation) {
        guard WCSession.isSupported(), session.isReachable else { return }
        
        // Minimal payload for low overhead
        let payload: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "ts": loc.timestamp.timeIntervalSince1970,
            "acc": loc.horizontalAccuracy
        ]
        
        session.sendMessage(["locations": [payload]], replyHandler: nil) { error in
            print("WC send error: \(error.localizedDescription)")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            print("Location authorization denied or restricted")
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            // Auto-start if authorized
            if isTracking {
                manager.startUpdatingLocation()
            }
        }
    }
}

extension WatchLocationManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("WCSession activated with state: \(activationState.rawValue)")
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        // iOS only
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        // iOS only - reactivate
        session.activate()
    }
    #endif
}


