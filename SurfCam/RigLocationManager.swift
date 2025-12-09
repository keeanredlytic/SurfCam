import CoreLocation
import Combine

enum RigCalibrationSource {
    case iphone
    case watch
}

class RigLocationManager: NSObject, ObservableObject {
    // Current GPS location (live)
    @Published var rigLocation: CLLocation?

    // Calibrated rig position (averaged over multiple samples)
    @Published var rigCalibratedCoord: CLLocationCoordinate2D?
    @Published var isCalibrating = false
    @Published var calibrationProgress: Double = 0  // 0..1
    @Published var calibrationSampleCount = 0
    @Published var calibrationError: String?
    @Published var calibrationAvgAccuracy: CLLocationAccuracy?
    @Published var calibrationSource: RigCalibrationSource?

    private let manager = CLLocationManager()

    // Calibration state
    private var rigSamples: [CLLocation] = []
    private var calibrationStartTime: Date?
    private var calibrationTimer: Timer?

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
        guard !isCalibrating else { return }

        rigSamples.removeAll()
        calibrationTimer?.invalidate()
        calibrationStartTime = Date()
        isCalibrating = true
        calibrationProgress = 0
        calibrationSampleCount = 0
        calibrationError = nil

        // Ensure we're getting high-accuracy GPS
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()

        // Timer to end calibration window after configured duration
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: CalibrationConfig.calibrationDuration,
                                                repeats: false) { [weak self] _ in
            self?.finishRigCalibration()
        }
    }

    /// Cancel ongoing rig calibration
    func cancelRigCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        isCalibrating = false
        calibrationProgress = 0
        rigSamples.removeAll()
    }

    private func finishRigCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        isCalibrating = false
        calibrationProgress = 1.0

        let samples = rigSamples
        rigSamples.removeAll()

        guard samples.count >= CalibrationConfig.minGoodSamples else {
            let msg = "Rig calibration failed: only \(samples.count) good samples (<\(CalibrationConfig.minGoodSamples))."
            calibrationError = msg
            print("❌ \(msg)")
            return
        }

        guard let avgCoord = RigLocationManager.weightedAverageCoordinate(from: samples) else {
            let msg = "Rig calibration failed: weighted average returned nil."
            calibrationError = msg
            print("❌ \(msg)")
            return
        }

        let avgAcc = samples.map { $0.horizontalAccuracy }.reduce(0, +) / Double(samples.count)
        calibrationAvgAccuracy = avgAcc
        calibrationSampleCount = samples.count
        calibrationSource = .iphone
        rigCalibratedCoord = avgCoord
        print("✅ Rig calibrated at \(avgCoord.latitude), \(avgCoord.longitude) from \(samples.count) samples, avgAcc=\(avgAcc)m (source=iphone)")
    }

    /// Clear the calibrated rig position
    func clearRigCalibration() {
        rigCalibratedCoord = nil
    }

    private static func weightedAverageCoordinate(from locations: [CLLocation]) -> CLLocationCoordinate2D? {
        guard !locations.isEmpty else { return nil }

        var sumLat = 0.0
        var sumLon = 0.0
        var sumWeight = 0.0

        for loc in locations {
            let acc = max(loc.horizontalAccuracy, 0.5) // avoid division by zero
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
}

extension RigLocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        let now = Date()

        // Track latest location for live use
        if let loc = locations.last {
            rigLocation = loc
        }

        guard isCalibrating, let start = calibrationStartTime else { return }

        for loc in locations {
            // Accuracy filter
            let acc = loc.horizontalAccuracy
            guard acc > 0, acc <= CalibrationConfig.maxCalibrationAccuracy else { continue }

            // Staleness filter
            let age = now.timeIntervalSince(loc.timestamp)
            guard abs(age) <= CalibrationConfig.sampleMaxAge else { continue }

            rigSamples.append(loc)
            calibrationSampleCount = rigSamples.count
            calibrationProgress = min(1.0, Double(calibrationSampleCount) / Double(CalibrationConfig.minGoodSamples))

            // Early completion when we reach the minimum required samples
            if calibrationSampleCount >= CalibrationConfig.minGoodSamples {
                finishRigCalibration()
                return
            }
        }
    }

    // MARK: - Watch-provided rig calibration
    func applyRigCalibrationFromWatch(coord: CLLocationCoordinate2D, samples: Int, avgAccuracy: CLLocationAccuracy) {
        rigCalibratedCoord = coord
        calibrationSampleCount = samples
        calibrationAvgAccuracy = avgAccuracy
        calibrationSource = .watch
        calibrationError = nil
        print("✅ Rig calibrated from WATCH – samples=\(samples), avgAcc=\(avgAccuracy)m")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Rig location error: \(error.localizedDescription)")
    }
}
