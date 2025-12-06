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

