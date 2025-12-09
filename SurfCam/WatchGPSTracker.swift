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
    @Published var watchCalibrationAvgAccuracy: CLLocationAccuracy?
    
    // Callback into camera layer when a fresh GPS point arrives
    var onLocationUpdate: (() -> Void)?
    // Callback for rig calibration arriving from Watch
    var onRigCalibrationFromWatch: ((CLLocationCoordinate2D, Int, CLLocationAccuracy) -> Void)?
    
    // Optional provider for rig coordinates to run distance sanity check
    var rigCoordinateProvider: (() -> CLLocationCoordinate2D?)?
    
    // Smoothing parameters
    private let smoothingAlpha: Double = 0.4  // faster response
    private var smoothedLocationInternal: CLLocation?
    
    // Staleness detection
    private var stalenessTimer: Timer?
    private var lastUpdateTime: Date = .distantPast
    
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
            self.isReceiving = timeSinceUpdate < CalibrationConfig.liveMaxAge
        }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            if let calibration = message["centerCalibration"] as? [String: Any],
               let lat = calibration["lat"] as? CLLocationDegrees,
               let lon = calibration["lon"] as? CLLocationDegrees {
                let samples = calibration["samples"] as? Int ?? 0
                let avgAcc = calibration["avgAccuracy"] as? CLLocationAccuracy
                self.handleCenterCalibration(coord: CLLocationCoordinate2D(latitude: lat, longitude: lon), sampleCount: samples, avgAccuracy: avgAcc)
                return
            } else if let rig = message["rigCalibration"] as? [String: Any],
                      let lat = rig["lat"] as? CLLocationDegrees,
                      let lon = rig["lon"] as? CLLocationDegrees,
                      let samples = rig["samples"] as? Int,
                      let avgAcc = rig["avgAccuracy"] as? CLLocationAccuracy {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if let handler = self.onRigCalibrationFromWatch {
                    handler(coord, samples, avgAcc)
                } else {
                    print("⚠️ Received rigCalibration from watch but no handler is set.")
                }
                return
            }
            
            if let array = message["locations"] as? [[Double]] {
                self.handleIncomingLocationsFromWatch(array)
                return
            }
            
            if let list = message["locations"] as? [[String: Any]] {
                // Legacy payload [{"lat":..,"lon":..,"ts":..,"acc":..}]
                let converted: [[Double]] = list.compactMap { item in
                    guard
                        let lat = item["lat"] as? CLLocationDegrees,
                        let lon = item["lon"] as? CLLocationDegrees,
                        let ts = item["ts"] as? TimeInterval
                    else { return nil }
                    let acc = item["acc"] as? CLLocationAccuracy ?? 10.0
                    return [lat, lon, ts, acc]
                }
                self.handleIncomingLocationsFromWatch(converted)
            }
        }
    }
    
    private func handleCenterCalibration(coord: CLLocationCoordinate2D, sampleCount: Int, avgAccuracy: CLLocationAccuracy?) {
        // Optional sanity check vs rig coordinate
        if let rigCoord = rigCoordinateProvider?() {
            let rigLoc = CLLocation(latitude: rigCoord.latitude, longitude: rigCoord.longitude)
            let centerLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let distance = rigLoc.distance(from: centerLoc)
            if distance < CalibrationConfig.minCenterDistanceFromRig {
                print("⚠️ Center calibration is too close to rig (\(distance)m). Recommend re-calibrating farther out.")
            } else {
                print("✅ Center calibration accepted. Distance from rig: \(distance)m")
            }
        }
        
        watchCalibratedCoord = coord
        watchCalibrationSampleCount = sampleCount
        watchCalibrationAvgAccuracy = avgAccuracy
    }
    
    private func handleIncomingLocationsFromWatch(_ array: [[Double]]) {
        let now = Date()
        for entry in array {
            guard entry.count >= 4 else { continue }
            let lat = entry[0]
            let lon = entry[1]
            let ts = entry[2]
            let acc = entry[3]
            
            let timestamp = Date(timeIntervalSince1970: ts)
            let age = now.timeIntervalSince(timestamp)
            
            // Accuracy filter
            guard acc > 0, acc <= CalibrationConfig.maxLiveAccuracy else { continue }
            
            // Staleness filter
            guard abs(age) <= CalibrationConfig.liveMaxAge else { continue }
            
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: 0,
                horizontalAccuracy: acc,
                verticalAccuracy: -1,
                timestamp: timestamp
            )
            processGoodLocation(location)
        }
    }
    
    private func processGoodLocation(_ location: CLLocation) {
        // Stats
        updateCount += 1
        let elapsed = Date().timeIntervalSince(statsResetTime)
        if elapsed > 1.0 {
            let rate = Double(updateCount) / elapsed
            DispatchQueue.main.async { self.updateRate = rate }
            updateCount = 0
            statsResetTime = Date()
        }
        
        lastUpdateTime = Date()
        let smoothed = updateSmoothedLocation(with: location)
        
        DispatchQueue.main.async {
            self.lastWatchLocation = location
            self.smoothedLocation = smoothed
            self.isReceiving = true
            self.latency = 0
            // Notify camera layer immediately on fresh GPS
            self.onLocationUpdate?()
        }
    }
    
    private func updateSmoothedLocation(with newLocation: CLLocation) -> CLLocation {
        let alpha = smoothingAlpha
        if let prev = smoothedLocationInternal {
            let lat = prev.coordinate.latitude * (1 - alpha) + newLocation.coordinate.latitude * alpha
            let lon = prev.coordinate.longitude * (1 - alpha) + newLocation.coordinate.longitude * alpha
            let blended = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: newLocation.altitude,
                horizontalAccuracy: newLocation.horizontalAccuracy,
                verticalAccuracy: newLocation.verticalAccuracy,
                timestamp: newLocation.timestamp
            )
            smoothedLocationInternal = blended
            return blended
        } else {
            smoothedLocationInternal = newLocation
            return newLocation
        }
    }
    
    // Reset smoothing (call when starting new tracking session)
    func resetSmoothing() {
        smoothedLocationInternal = nil
        smoothedLocation = nil
        lastWatchLocation = nil
    }
    
    // Clear watch center calibration
    func clearWatchCalibration() {
        watchCalibratedCoord = nil
        watchCalibrationSampleCount = 0
        watchCalibrationAvgAccuracy = nil
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
