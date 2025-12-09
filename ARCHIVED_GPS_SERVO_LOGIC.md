## Archived GPS Servo Logic (for future re-use)

This is the previous GPS-driven servo path. It was disabled in code to allow a rework. Keep this snippet if you need to reintroduce GPS-based pointing later.

### Functions (from `CameraScreen.swift`)

```swift
/// Distance + motion aware GPS servo update.
/// Call this in watchGPS mode and GPS-driven portions of gpsAI (searching/lost).
private func tickGPSServoWithDistanceAndMotion() {
    guard
        let filteredBearing = gpsFilteredBearing,
        let center = calibratedBearing
    else {
        return
    }
    
    // If GPS is stale, don't drive servo with old data
    guard gpsTracker.isReceiving else { return }
    
    let d = gpsDistanceMeters
    let v = gpsSpeedMps
    
    let targetAngle = servoTargetAngle(forBearing: filteredBearing, calibrated: center)
    let currentAngle = Double(api.currentAngle)
    let error = (targetAngle - currentAngle) * -1.0  // mirror GPS direction
    
    let deadband = servoDeadbandDegrees(forDistance: d)
    if abs(error) < deadband {
        return
    }
    
    let maxStep = servoMaxStepDegrees(forDistance: d, speed: v)
    let step = max(-maxStep, min(maxStep, error))
    
    let proposed = currentAngle + step
    let clamped = Double(clampAngle(CGFloat(proposed)))
    
    api.track(angle: Int(clamped))
}
```

If re-enabling later:
- Restore the body above into `tickGPSServoWithDistanceAndMotion()`.
- Ensure mirroring `(targetAngle - currentAngle) * -1.0` remains if needed for your rig direction.
- Confirm GPS gating / fusion flows call this function where desired.

