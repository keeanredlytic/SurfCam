import CoreLocation
import WatchConnectivity
import HealthKit

enum CalibrationMode {
    case none
    case center
    case rig
}

class WatchLocationManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    @Published var currentLocation: CLLocation?
    @Published var isTracking = false
    @Published var accuracy: Double = -1  // Current GPS accuracy in meters
    @Published var updateRate: Double = 0  // Updates per second

    // Center / rig calibration state
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0  // 0..1
    @Published var calibrationSampleCount = 0
    @Published var lastCalibrationResult: String?  // Status message
    private var calibrationMode: CalibrationMode = .none
    
    private let manager = CLLocationManager()
    private let session = WCSession.default

    // HealthKit workout session to keep GPS alive and frequent
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    // Rate limiting and filtering
    private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 0.2  // ~5 Hz max (matches servo loop)


    // MARK: - Subject lock (Vision assist)
    /// Ask the phone to lock the current subject (color + size) via WCSession.
    func requestSubjectLock() {
        guard WCSession.isSupported(), session.isReachable else {
            print("⚠️ Phone not reachable for lockSubject")
            return
        }
        session.sendMessage(["lockSubject": true], replyHandler: nil) { error in
            print("❌ Failed to send lockSubject: \(error.localizedDescription)")
        }
    }
    // Center calibration
    private var calibrationSamples: [CLLocation] = []
    private var calibrationTimer: Timer?
    private var calibrationStartTime: Date?

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
        guard !isCalibrating else { return }
        calibrationMode = .center
        beginCalibration()
    }
    
    /// Start rig calibration from watch (hold watch over the tripod)
    func startRigCalibrationFromWatch() {
        guard !isCalibrating else { return }
        calibrationMode = .rig
        beginCalibration()
    }
    
    private func beginCalibration() {
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
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
            manager.startUpdatingLocation()
        } else {
            requestAuthorizationIfNeeded()
        }

        calibrationTimer = Timer.scheduledTimer(withTimeInterval: CalibrationConfig.calibrationDuration, repeats: false) { [weak self] _ in
            self?.finishCalibration()
        }
    }

    /// Cancel ongoing calibration
    func cancelCenterCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        isCalibrating = false
        calibrationProgress = 0
        calibrationSamples.removeAll()
        calibrationMode = .none
    }

    private func finishCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil

        DispatchQueue.main.async {
            self.isCalibrating = false
            self.calibrationProgress = 1.0
        }

        let samples = calibrationSamples
        calibrationSamples.removeAll()

        guard samples.count >= CalibrationConfig.minGoodSamples else {
            DispatchQueue.main.async {
                self.lastCalibrationResult = "❌ Failed (too few samples)"
            }
            print("❌ Calibration failed: only \(samples.count) good samples (<\(CalibrationConfig.minGoodSamples)).")
            calibrationMode = .none
            return
        }

        guard let avgCoord = WatchLocationManager.weightedAverageCoordinate(from: samples) else {
            DispatchQueue.main.async {
                self.lastCalibrationResult = "❌ Failed (no average)"
            }
            print("❌ Calibration failed: no averaged coord.")
            calibrationMode = .none
            return
        }

        let avgAccuracy = samples.map { $0.horizontalAccuracy }.reduce(0, +) / Double(samples.count)

        // Send calibration to phone via WatchConnectivity
        switch calibrationMode {
        case .center:
            sendCenterCalibrationToPhone(avgCoord, sampleCount: samples.count, avgAccuracy: avgAccuracy)
            DispatchQueue.main.async { self.lastCalibrationResult = "✅ Center sent" }
            print("✅ Center calibrated at \(avgCoord.latitude), \(avgCoord.longitude) from \(samples.count) samples, avgAcc=\(avgAccuracy)m")
        case .rig:
            sendRigCalibrationToPhone(avgCoord, sampleCount: samples.count, avgAccuracy: avgAccuracy)
            DispatchQueue.main.async { self.lastCalibrationResult = "✅ Rig sent" }
            print("✅ Rig (watch) calibrated at \(avgCoord.latitude), \(avgCoord.longitude) from \(samples.count) samples, avgAcc=\(avgAccuracy)m")
        case .none:
            break
        }
        
        calibrationMode = .none
    }

    private func sendCenterCalibrationToPhone(_ coord: CLLocationCoordinate2D, sampleCount: Int, avgAccuracy: CLLocationAccuracy) {
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
                "samples": sampleCount,
                "avgAccuracy": avgAccuracy
            ]
        ]

        session.sendMessage(payload, replyHandler: nil) { [weak self] error in
            print("Failed to send calibration: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self?.lastCalibrationResult = "❌ Send failed"
            }
        }
    }
    
    private func sendRigCalibrationToPhone(_ coord: CLLocationCoordinate2D, sampleCount: Int, avgAccuracy: CLLocationAccuracy) {
        guard WCSession.isSupported(), session.isReachable else {
            DispatchQueue.main.async {
                self.lastCalibrationResult = "⚠️ Phone not reachable"
            }
            return
        }

        let payload: [String: Any] = [
            "rigCalibration": [
                "lat": coord.latitude,
                "lon": coord.longitude,
                "samples": sampleCount,
                "avgAccuracy": avgAccuracy
            ]
        ]

        session.sendMessage(payload, replyHandler: nil) { [weak self] error in
            print("Failed to send rig calibration: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self?.lastCalibrationResult = "❌ Rig send failed"
            }
        }
    }

    private static func weightedAverageCoordinate(from locations: [CLLocation]) -> CLLocationCoordinate2D? {
        guard !locations.isEmpty else { return nil }

        var sumLat = 0.0
        var sumLon = 0.0
        var sumWeight = 0.0

        for loc in locations {
            let acc = max(loc.horizontalAccuracy, 0.5)
            let w = 1.0 / (acc * acc)
            sumLat += loc.coordinate.latitude * w
            sumLon += loc.coordinate.longitude * w
            sumWeight += w
        }

        guard sumWeight > 0 else { return nil }

        return CLLocationCoordinate2D(
            latitude: sumLat / sumWeight,
            longitude: sumLon / sumWeight
        )
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
        let now = Date()

        // Update stats
        updateCount += 1
        let elapsedStats = now.timeIntervalSince(lastStatsReset)
        if elapsedStats > 1.0 {
            DispatchQueue.main.async {
                self.updateRate = Double(self.updateCount) / elapsedStats
            }
            updateCount = 0
            lastStatsReset = now
        }

        // Always update local display
        DispatchQueue.main.async {
            self.currentLocation = loc
            self.accuracy = loc.horizontalAccuracy
        }

        // Center calibration sampling
        if isCalibrating, let start = calibrationStartTime {
            for sample in locations {
                let elapsed = now.timeIntervalSince(start)
                DispatchQueue.main.async {
                    self.calibrationProgress = min(1.0, elapsed / CalibrationConfig.calibrationDuration)
                }

                let acc = sample.horizontalAccuracy
                guard acc > 0, acc <= CalibrationConfig.maxCalibrationAccuracy else { continue }

                let age = now.timeIntervalSince(sample.timestamp)
                guard abs(age) <= CalibrationConfig.sampleMaxAge else { continue }

                calibrationSamples.append(sample)
                DispatchQueue.main.async {
                    self.calibrationSampleCount = self.calibrationSamples.count
                    if self.calibrationSampleCount >= CalibrationConfig.minGoodSamples {
                        self.finishCalibration()
                    }
                }
            }
        }

        // --- FILTERING: Only send good, fresh points ---
        // 1) Reject invalid accuracy (negative means invalid)
        if loc.horizontalAccuracy < 0 {
            return
        }

        // 2) Reject poor accuracy (> maxLiveAccuracy meters)
        if loc.horizontalAccuracy > CalibrationConfig.maxLiveAccuracy {
            print("Skipping low accuracy point: \(loc.horizontalAccuracy)m")
            return
        }

        // 3) Reject stale timestamps (> liveMaxAge seconds old)
        if abs(loc.timestamp.timeIntervalSinceNow) > CalibrationConfig.liveMaxAge {
            print("Skipping stale point: \(abs(loc.timestamp.timeIntervalSinceNow))s old")
            return
        }

        // 4) Rate limit sends (~5 Hz max)
        let nowSend = Date()
        if nowSend.timeIntervalSince(lastSentAt) < minSendInterval {
            return
        }
        lastSentAt = nowSend

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
