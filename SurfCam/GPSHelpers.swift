import CoreLocation

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

// MARK: - GPS-based Expected Screen Position

/// Horizontal field of view in degrees - adjust per camera lens
/// ~60° for wide angle, ~40° for telephoto
let cameraHFOV: Double = 60

/// Calculate expected screen X position (0..1) based on GPS data
/// Returns nil if the target should be outside the camera's field of view
///
/// - Parameters:
///   - rigCoord: The calibrated rig/tripod location
///   - watchCoord: Current watch GPS location
///   - calibratedBearing: The "center" bearing (where 0.5 on screen should be)
///   - currentCameraHeading: Current servo angle mapped to compass heading
/// - Returns: Expected X position (0..1) or nil if outside FOV
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

