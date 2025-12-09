import CoreLocation

struct CalibrationConfig {
    // Rig & center calibration
    static let calibrationDuration: TimeInterval = 120.0     // seconds
    static let sampleMaxAge: TimeInterval = 2.0              // reject stale
    static let maxCalibrationAccuracy: CLLocationAccuracy = 3.0 // meters
    static let minGoodSamples: Int = 10

    // Live GPS for tracking
    static let maxLiveAccuracy: CLLocationAccuracy = 3.0     // meters
    static let liveMaxAge: TimeInterval = 2.0                // stale threshold

    // Distance sanity for center calibration (used on phone)
    static let minCenterDistanceFromRig: CLLocationDistance = 15.0 // meters
}

