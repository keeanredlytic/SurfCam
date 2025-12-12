# SurfCam AI Tracking – Full Reference

**Purpose:** Complete, code-level reference for the current AI tracking pipeline (Vision-based), its integration points, and how it interacts with GPS/zoom state (with GPS servo control currently archived). Use this to refactor/optimize without hunting through code.

---

## Primary Files (AI Path)
- `SurfCam/CameraScreen.swift` — main controller, mode dispatch, state machine, AI follower, calibration glue.
- `SurfCam/FaceTracker.swift` — Vision detection, scoring, smoothing.
- `SurfCam/GPSHelpers.swift` — bearing/servo helpers (AI uses servo clamping).
- `SurfCam/ZoomController.swift` — zoom presets; autoDistance currently enabled but GPS servo is disabled.
- `SurfCam/CameraSessionManager.swift` — camera setup; provides frames to FaceTracker; zoom clamping.

---

## Modes (CameraScreen)
- `TrackingMode.cameraAI` (AI-only): auto-starts, Vision controls servo. **This is the primary mode exposed in UI.**
- `TrackingMode.gpsAI` (fusion): state machine; in `.locked`, AI controls servo; GPS servo currently disabled/archived. **Hidden from UI.**
- `TrackingMode.watchGPS` (GPS-only): GPS servo disabled/archived; Vision not used for servo. **Hidden from UI.**
- `TrackingMode.off`: no tracking.

**UI Simplification:** The UI only exposes a simple "Tracking On/Off" toggle that switches between `.off` and `.cameraAI`. GPS/AI+ modes are still available internally but not exposed in the UI.

---

## State Machine (CameraScreen)
- States: `.searching`, `.locked`, `.lost`
- Thresholds: `lockFramesThreshold = 12`, `lostFramesThreshold = 8`, drift: 30% for 15 frames (only when fusion enabled).
- In `cameraAI`: state machine still runs for lock/lost bookkeeping but servo control is Vision only.

**Pan-Priority Movement:** In `trackWithCameraAI()`, pan is tried first. If pan moves (returns `true`), tilt is skipped for that tick. This prevents diagonal "spaz" behavior where both servos move simultaneously. Only one axis moves per tracking tick.

---

## Vision Follower (CameraScreen.applyVisionFollower)

Returns `Bool` indicating whether a pan move was commanded (true) or not (false, within deadband).

```swift
private func applyVisionFollower(from faceCenter: CGPoint) -> Bool {
    let x = faceCenter.x // 0..1

    // Zoom-aware control tuning
    let zoom = zoomController.zoomFactor
    let zoomClamped = max(1.0, min(zoom, 8.0))

    let baseGain: CGFloat = 10.0
    let baseDeadband: CGFloat = 0.02
    let baseMaxStep: CGFloat = 4.0

    let gainScale = 1.0 / (1.0 + 0.25 * (zoomClamped - 1.0))
    let gain = baseGain * gainScale

    let deadbandScale = 1.0 + 0.5 * (zoomClamped - 1.0) / 7.0
    let deadband: CGFloat = baseDeadband * deadbandScale

    let maxStep: CGFloat = baseMaxStep * gainScale

    let servoMirror: CGFloat = -1.0
    let baseBiasDegrees: CGFloat = centerBiasDegrees
    let lensBiasDegrees: CGFloat = zoomController.currentPreset.lensCenterBiasDegrees
    let totalBiasDegrees = baseBiasDegrees + lensBiasDegrees
    let centerBiasNorm = totalBiasDegrees / gain

    let offset = (x + centerBiasNorm) - 0.5
    
    // ❗️No move = return false
    if abs(offset) < deadband { return false }

    var step = offset * gain * servoMirror
    step = max(-maxStep, min(maxStep, step))

    let currentAngle = CGFloat(api.currentPanAngle)
    let newAngle = clampAngle(currentAngle + step) // 15–165
    sendPanAngle(Int(newAngle))

    return true
}
```
- **Returns**: `true` if pan moved, `false` if within deadband
- **Clamping**: `clampAngle` enforces 15°–165°.
- **Bias**: base + per-lens bias via `LensCalibrationManager`.
- **Mirror**: servoMirror = -1.0 (Vision path).

---

## Tilt Follower (CameraScreen.applyTiltFollower)

Returns `Bool` indicating whether a tilt move was commanded (true) or not (false, within deadband). Tilt uses the same control logic as pan (same gain/deadband/maxStep pattern) for consistent behavior. The deadband is larger (5% vs 2%) to account for natural vertical bobbing in waves.

```swift
private func applyTiltFollower(from faceCenter: CGPoint) -> Bool {
    let y = faceCenter.y // 0..1, top → bottom

    // We want the surfer slightly below center
    let desiredY: CGFloat = 0.55

    // Zoom-aware control tuning – mirror of pan
    let zoom = zoomController.zoomFactor
    let zoomClamped = max(1.0, min(zoom, 8.0))

    let baseGain: CGFloat = 10.0      // 🔁 same as pan
    let baseDeadband: CGFloat = 0.05  // 🔥 5% vertical no-move zone (larger than pan for natural bobbing)
    let baseMaxStep: CGFloat = 4.0    // 🔁 same as pan (max degrees per tick)

    let gainScale = 1.0 / (1.0 + 0.25 * (zoomClamped - 1.0))
    let gain = baseGain * gainScale

    let deadbandScale = 1.0 + 0.5 * (zoomClamped - 1.0) / 7.0
    let deadband: CGFloat = baseDeadband * deadbandScale

    let maxStep: CGFloat = baseMaxStep * gainScale

    // Offset: how far we are from desired vertical position
    // y > desiredY means surfer is lower in the frame
    var offset = y - desiredY

    // If this moves the wrong way, just flip the sign:
    // offset = desiredY - y

    // ❗️No move = return false
    if abs(offset) < deadband { return false }

    // Direction scaling – flip to match your physical tilt orientation if needed
    let tiltDirection: CGFloat = 1.0  // set to -1.0 if inverted

    var step = offset * gain * tiltDirection
    step = max(-maxStep, min(maxStep, step)) // clamp like pan

    let currentTilt = CGFloat(api.currentTiltAngle)
    let newTilt = clampTiltAngle(currentTilt + step) // 80–180
    sendTiltAngle(Int(newTilt))

    return true
}
```
- **Returns**: `true` if tilt moved, `false` if within deadband
- **Tilt clamp**: `clampTiltAngle` enforces 80°–180° (matches ESP32 tilt limits).
- **Same control pattern as pan**: Uses identical gain (10.0), maxStep (4.0), and zoom-aware scaling.
- **Larger deadband**: 5% vertical no-move zone (vs 2% for pan) to allow natural bobbing without constant corrections.
- **Zoom-aware deadband**: Deadband scales with zoom, getting slightly wider at high zoom levels.
- **Direction**: If tilt moves the opposite way expected, flip `tiltDirection` to -1.0.

---

## FaceTracker.swift (Vision Pipeline)
- Receives frames via `CameraSessionManager` video output.
- Detection: `VNDetectHumanRectanglesRequest`.
- Filtering: confidence ≥ 0.5.
- **Hard Lock System**: When subject is locked, prioritizes specific detection ID above all scoring. Only releases after `hardLockLostThreshold` frames (~1s) without seeing the locked target.
- Scoring (multi-factor with adaptive color weighting):
  - **Normal mode**: `score = 0.20 * gpsScore + 0.25 * continuityScore + 0.20 * sizeScore + 0.35 * colorScore`
  - **Reacquire mode** (no previous center but color locked): `score = 0.15 * gpsScore + 0.10 * continuityScore + 0.30 * sizeScore + 0.45 * colorScore`
  - gpsScore = 1.0 if within 30% of expectedX, else decays (optional, when GPS gating enabled).
  - continuityScore = 1.0 near previous center, decays with distance.
  - sizeScore: aspect-ratio aware (prone favors width, standing favors area).
  - colorScore: cosine similarity to locked target color (0..1, only when subject locked).
  - **Adaptive weighting**: When continuity is unavailable (reacquire), color becomes dominant (45%) to find the same subject by color signature.
- Smoothing:
  - Horizontal: alphaX = 0.7 (more weight on new data → snappier pan)
  - Vertical: alphaY = 0.45 (slightly snappier tilt, still smooth-ish)
  - `newCenter = prev * (1 - alpha) + raw * alpha`
- Color tracking:
  - Subject lock via `shouldLockSubject` flag (triggered by UI/Watch).
  - Color captured from detection bbox, stored as normalized RGB `SIMD3<Float>`.
  - Color similarity computed via normalized dot product (brightness-invariant).
  - Hard lock: locks specific detection ID when subject is locked, ensuring that ID is always chosen when present.
- Published outputs:
  - `faceCenter: CGPoint?` (current Vision tracking center - red dot)
  - `targetBoundingBox: CGRect?` (normalized 0..1; set when target chosen, cleared on loss/reset)
  - `expectedX: CGFloat?` (when GPS gating is on)
  - `useGPSGating: Bool`
  - `shouldLockSubject: Bool` (trigger for explicit color+size+ID lock)
  - `onSubjectSizeLocked` callback (publishes baseline width/height when lock occurs)
  - **Debug properties** (for UI visualization):
    - `isColorLockActive: Bool` (true when color lock is active)
    - `hardLockCenter: CGPoint?` (normalized 0..1 center of locked subject - blue ring)
    - `lockedColorPreview: UIColor?` (preview color for UI swatch)
    - `lockedColorDebugText: String` (RGB text like "R:210 G:35 B:40")
    - `isUsingColorReacquire: Bool` (true when in grace window using color-heavy reacquire)
  - Tracking reset via `resetTracking()` (clears hard lock state and debug properties).

### FaceTracker scoring/smoothing (key snippets)
```swift
// Detection model
struct PersonDetection: Identifiable {
    let id: UUID
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let confidence: Float
    var area: CGFloat { width * height }
    var aspectRatio: CGFloat { width / max(height, 0.0001) }
}

// Smoothing (applied after detection)
let alphaX: CGFloat = 0.7   // more weight on new data → snappier pan
let alphaY: CGFloat = 0.45  // slightly snappier tilt, still smooth-ish
let newCenter = CGPoint(
    x: prev.x * (1 - alphaX) + raw.x * alphaX,
    y: prev.y * (1 - alphaY) + raw.y * alphaY
)

// Color-aware scoring (GPS optional)
func scorePerson(_ person: PersonDetection,
                 expectedX: CGFloat?,
                 previousCenter: CGPoint?,
                 pixelBuffer: CVPixelBuffer?) -> CGFloat {
    var gpsScore: CGFloat = 0
    if let expX = expectedX {
        let dx = abs(person.x - expX)
        if dx < 0.3 { gpsScore = 1.0 - dx/0.3 }
    }
    var continuity: CGFloat = 0
    if let prev = previousCenter {
        let dist = hypot(person.x - prev.x, person.y - prev.y)
        if dist < 0.2 { continuity = 1.0 - dist/0.2 }
    }
    let ar = person.aspectRatio
    let isProne = ar < 0.6
    let widthScore = min(1.0, person.width / 0.10)
    let areaScore  = min(1.0, person.area / 0.02)
    let sizeScore = isProne ? widthScore : areaScore
    let colorScore = computeColorScore(for: person, pixelBuffer: pixelBuffer)
    
    // Adaptive weights: stronger color when reacquiring (no previous center but have color lock)
    let hasPrevCenter = (previousCenter != nil)
    let hasColorLock = (targetColor != nil && targetColorStrength > 0.1)
    let isReacquiring = (!hasPrevCenter && hasColorLock)
    
    let wGPS: CGFloat, wCont: CGFloat, wSize: CGFloat, wColor: CGFloat
    if isReacquiring {
        // Reacquire mode: color is dominant (45%), continuity minimal (10%)
        wGPS = 0.15; wCont = 0.10; wSize = 0.30; wColor = 0.45
    } else {
        // Normal mode: balanced with stronger color (35%, up from 20%)
        wGPS = 0.20; wCont = 0.25; wSize = 0.20; wColor = 0.35
    }
    
    return wGPS * gpsScore + wCont * continuity + wSize * sizeScore + wColor * colorScore
}

// Target selection (with hard lock support)
// This is called from the Vision frame processing loop:
var chosen: PersonDetection

if isHardLocked, let lockedID = lockedTargetID {
    // Try to find the locked target in this frame
    if let lockedDetection = detections.first(where: { $0.id == lockedID }) {
        // ✅ Still seeing the locked subject – use it and ONLY it
        chosen = lockedDetection
        framesSinceLockedSeen = 0
    } else {
        // 🚨 Locked subject not detected in this frame
        framesSinceLockedSeen &+= 1
        
        if framesSinceLockedSeen <= hardLockLostThreshold {
            // Still within grace window – try to reacquire by color/score
            chosen = pickBestTarget(
                candidates: detections,
                expectedX: expectedX,
                previousCenter: nil,      // continuity is unreliable here
                pixelBuffer: pixelBuffer
            )
        } else {
            // Too long without seeing locked subject – drop hard lock
            print("⚠️ Hard lock expired after \(framesSinceLockedSeen) frames without subject.")
            isHardLocked = false
            lockedTargetID = nil
            framesSinceLockedSeen = 0
            
            // Fallback to normal best-target behavior
            chosen = pickBestTarget(
                candidates: detections,
                expectedX: expectedX,
                previousCenter: previousCenter,
                pixelBuffer: pixelBuffer
            )
        }
    }
} else {
    // No hard lock – normal scoring-based choice
    framesSinceLockedSeen = 0
    chosen = pickBestTarget(
        candidates: detections,
        expectedX: expectedX,
        previousCenter: previousCenter,
        pixelBuffer: pixelBuffer
    )
}

// Helper function for normal scoring-based selection
func pickBestTarget(candidates: [PersonDetection],
                    expectedX: CGFloat?,
                    previousCenter: CGPoint?,
                    pixelBuffer: CVPixelBuffer?) -> PersonDetection {
    return candidates.max {
        scorePerson($0, expectedX: expectedX, previousCenter: previousCenter, pixelBuffer: pixelBuffer)
        < scorePerson($1, expectedX: expectedX, previousCenter: previousCenter, pixelBuffer: pixelBuffer)
    }!
}

// Publishing the chosen target (normalized 0..1)
self.smoothedCenter = newCenter
self.faceCenter = newCenter
self.allDetections = detections
self.currentTargetID = chosen.id
self.targetBoundingBox = CGRect(
    x: chosen.x - chosen.width / 2,
    y: chosen.y - chosen.height / 2,
    width: chosen.width,
    height: chosen.height
)
// Cleared on loss/reset.
```

---

## Color Tracking System (Subject Lock)

The color tracking system allows the AI to maintain lock on a specific subject by matching their color signature. This is especially useful in crowded environments or when the subject goes prone (where size-based tracking becomes less reliable).

### Overview

- **Purpose**: Maintain consistent tracking of a specific subject by color matching and ID-based hard lock
- **Trigger**: User-initiated via "Lock Surfer" button (iPhone UI or Apple Watch)
- **Storage**: Target color stored as `SIMD3<Float>` (RGB normalized 0..1)
- **Integration**: Color score contributes 35% weight (normal) or 45% weight (reacquire) to overall person scoring
- **Hard Lock**: When subject is locked, system prioritizes the specific detection ID, only releasing after prolonged absence
- **Persistence**: Color lock and hard lock persist for the entire session until reset

### State Management (FaceTracker)

```swift
// Color/size lock state
private var targetColor: SIMD3<Float>?           // Locked RGB color (normalized 0..1)
private var targetColorStrength: Float = 0.0     // Strength multiplier (0..1)
private var lastColorBox: CGRect?                // Last bounding box used for color lock

// Hard subject lock state
private var lockedTargetID: UUID?                // ID of the locked subject
private var isHardLocked: Bool = false          // Whether hard lock is active
private var framesSinceLockedSeen: Int = 0      // Frames since locked target was last seen
private let hardLockLostThreshold: Int = 20      // ~1s at 20 Hz (tune as needed)

// Subject lock trigger (set by CameraScreen)
@Published var shouldLockSubject: Bool = false

// Callback to publish baseline size when lock occurs
var onSubjectSizeLocked: ((_ width: CGFloat, _ height: CGFloat) -> Void)?

// MARK: - Debug / UI helpers

/// True when we currently have a color lock with meaningful strength.
@Published var isColorLockActive: Bool = false

/// Normalized 0..1 center of the hard-locked subject (for blue debug dot).
/// This will track the chosen target while hard lock is active.
@Published var hardLockCenter: CGPoint?

/// Preview color of the locked subject (for UI swatch).
@Published var lockedColorPreview: UIColor?

/// Simple RGB debug text (0–255) for logging / overlay.
@Published var lockedColorDebugText: String = ""

/// True when we are in the hard-lock grace window using color-heavy reacquire.
@Published var isUsingColorReacquire: Bool = false
```

### Locking Process

**1. User Request (CameraScreen)**
```swift
func requestSubjectLock() {
    faceTracker.shouldLockSubject = true
    print("🎯 Subject lock requested from UI/Watch.")
}
```

**2. Lock Execution (FaceTracker)**
When `shouldLockSubject == true` and a valid detection is found:
```swift
// Inside Vision frame processing, after choosing best target:
if self.shouldLockSubject,
   let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
    self.lockColorAndSize(from: pixelBuffer, using: chosen)
    self.shouldLockSubject = false
}
```

**3. Color + Size Capture + Hard Lock**
```swift
func lockColorAndSize(
    from pixelBuffer: CVPixelBuffer,
    using detection: PersonDetection
) {
    let bbox = CGRect(
        x: detection.x - detection.width / 2,
        y: detection.y - detection.height / 2,
        width: detection.width,
        height: detection.height
    )

    guard let avg = averageColor(in: bbox, from: pixelBuffer) else {
        print("⚠️ Failed to compute average color for lock.")
        return
    }

    // Strongly set color
    targetColor = avg
    targetColorStrength = 1.0
    lastColorBox = bbox

    // Hard lock: remember this specific target ID
    isHardLocked = true
    lockedTargetID = detection.id
    framesSinceLockedSeen = 0

    // Publish normalized bbox as baseline size via callback
    // Note: baseline size is captured for UI/display purposes, but auto-zoom now uses a fixed 6% target
    let width = detection.width
    let height = detection.height
    onSubjectSizeLocked?(width, height)

    // 🔵 Debug: color lock is active
    isColorLockActive = true

    // 🔵 Debug: store center of locked detection for blue dot (normalized 0..1)
    let center = CGPoint(x: detection.x, y: detection.y)
    hardLockCenter = center

    // 🔵 Debug: preview color & RGB text
    let r = CGFloat(avg.x)
    let g = CGFloat(avg.y)
    let b = CGFloat(avg.z)

    let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)
    lockedColorPreview = uiColor

    let r255 = Int(round(r * 255.0))
    let g255 = Int(round(g * 255.0))
    let b255 = Int(round(b * 255.0))
    lockedColorDebugText = "R:\(r255) G:\(g255) B:\(b255)"

    print("✅ Hard-locked subject ID \(detection.id), color + size. width=\(width), height=\(height), \(lockedColorDebugText)")
}
```

### Color Sampling (averageColor)

Extracts average RGB color from a bounding box region in the pixel buffer:

```swift
private func averageColor(in bbox: CGRect, from pixelBuffer: CVPixelBuffer) -> SIMD3<Float>? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width  = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    // Convert normalized bbox → pixel coords and expand slightly (10% padding)
    var rect = bbox
    rect.origin.x *= CGFloat(width)
    rect.origin.y *= CGFloat(height)
    rect.size.width  *= CGFloat(width)
    rect.size.height *= CGFloat(height)
    rect = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1) // expand 10%
    rect.origin.x = max(0, rect.origin.x)
    rect.origin.y = max(0, rect.origin.y)
    rect.size.width = min(CGFloat(width) - rect.origin.x, rect.size.width)
    rect.size.height = min(CGFloat(height) - rect.origin.y, rect.size.height)

    let x0 = Int(rect.origin.x)
    let y0 = Int(rect.origin.y)
    let x1 = Int(rect.origin.x + rect.size.width)
    let y1 = Int(rect.origin.y + rect.size.height)

    var rSum: Float = 0
    var gSum: Float = 0
    var bSum: Float = 0
    var count: Int = 0

    for y in y0..<y1 {
        let rowPtr = baseAddr.advanced(by: y * bytesPerRow)
        for x in x0..<x1 {
            let p = rowPtr.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
            // BGRA format
            let b = Float(p[0])
            let g = Float(p[1])
            let r = Float(p[2])
            rSum += r; gSum += g; bSum += b
            count += 1
        }
    }

    guard count > 0 else { return nil }
    // Return normalized RGB (0..1)
    return SIMD3<Float>(rSum / Float(count),
                        gSum / Float(count),
                        bSum / Float(count)) / 255.0
}
```

**Key details:**
- Samples BGRA pixel buffer directly
- Expands bbox by 10% to capture more context
- Clamps to valid pixel bounds
- Returns normalized RGB (0..1) as `SIMD3<Float>`

### Color Similarity (colorSimilarity)

Computes cosine similarity between two normalized RGB vectors:

```swift
private func colorSimilarity(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let da = simd_normalize(a)  // Normalize first color vector
    let db = simd_normalize(b)  // Normalize second color vector
    let dot = max(0, simd_dot(da, db))  // Dot product (cosine similarity)
    return dot // 0..1, where 1 = identical, 0 = orthogonal
}
```

**Why normalize?**
- Makes similarity independent of brightness (lighting changes)
- Focuses on hue/saturation matching
- Returns 0..1 score where 1.0 = perfect match

### Color Score Integration

**1. Compute Color Score**
```swift
private func computeColorScore(
    for person: PersonDetection,
    pixelBuffer: CVPixelBuffer?
) -> CGFloat {
    guard let target = targetColor,
          targetColorStrength > 0.1,
          let pixelBuffer = pixelBuffer else {
        return 0.0  // No color lock active
    }

    let bbox = CGRect(
        x: person.x - person.width / 2,
        y: person.y - person.height / 2,
        width: person.width,
        height: person.height
    )

    guard let avg = averageColor(in: bbox, from: pixelBuffer) else { return 0.0 }
    let sim = colorSimilarity(target, avg) // 0..1
    let score = sim * targetColorStrength   // Scale by strength
    return CGFloat(score)
}
```

**2. Adaptive Weighted Scoring**
Color score weight adapts based on tracking state:

**Normal mode** (has previous center):
- Color: 35% (increased from 20% for better subject distinction)
- Continuity: 25%
- Size: 20%
- GPS: 20%

**Reacquire mode** (no previous center but color locked):
- Color: 45% (dominant signal to find same subject by color)
- Size: 30% (still matters for proximity)
- GPS: 15%
- Continuity: 10% (minimal, since we have no previous position)

```swift
// Detect reacquire situation
let hasPrevCenter = (previousCenter != nil)
let hasColorLock = (targetColor != nil && targetColorStrength > 0.1)
let isReacquiring = (!hasPrevCenter && hasColorLock)

let wGPS: CGFloat, wCont: CGFloat, wSize: CGFloat, wColor: CGFloat
if isReacquiring {
    wGPS = 0.15; wCont = 0.10; wSize = 0.30; wColor = 0.45
} else {
    wGPS = 0.20; wCont = 0.25; wSize = 0.20; wColor = 0.35
}

return wGPS * gpsScore
     + wCont * continuityScore
     + wSize * sizeScore
     + wColor * colorScore
```

**Rationale**: When continuity is lost (duck-dive, fall, occlusion), color becomes the primary signal to reacquire the same subject, especially in crowded conditions.

### Hard Lock System

The hard lock system ensures that once a subject is locked, the system prioritizes that specific detection ID above all other candidates, even if another person scores higher.

**Behavior:**
1. **When locked target is present**: The system **must** choose the locked target ID, regardless of scoring. No other person can "outscore" them.
2. **When locked target is missing (grace period)**: For up to `hardLockLostThreshold` frames (~1 second at 20 Hz), the system:
   - Remains in hard lock state
   - Uses color-heavy reacquire mode (45% color weight) to try to find the same subject
   - Passes `previousCenter: nil` to scoring, triggering reacquire weights
3. **After grace period expires**: Hard lock is dropped, system returns to normal scoring behavior

**Key Code (from FaceTracker.process):**
```swift
if isHardLocked, let lockedID = lockedTargetID {
    if let lockedDetection = detections.first(where: { $0.id == lockedID }) {
        // ✅ Locked target still present – use it exclusively
        chosen = lockedDetection
        framesSinceLockedSeen = 0
        
        // 🔵 Debug: hard lock center tracks this subject
        DispatchQueue.main.async {
            self.hardLockCenter = CGPoint(x: lockedDetection.x, y: lockedDetection.y)
            self.isUsingColorReacquire = false
        }
    } else {
        // 🚨 Locked target missing
        framesSinceLockedSeen &+= 1
        
        if framesSinceLockedSeen <= hardLockLostThreshold {
            // Grace window – we are in color-heavy reacquire mode
            DispatchQueue.main.async {
                self.isUsingColorReacquire = true
            }
            
            chosen = pickBestTarget(
                candidates: detections,
                expectedX: expectedX,
                previousCenter: nil,  // Triggers reacquire mode (45% color)
                pixelBuffer: pixelBuffer
            )
            
            // 🔵 Debug: hardLockCenter moves with chosen reacquire target
            DispatchQueue.main.async {
                self.hardLockCenter = CGPoint(x: chosen.x, y: chosen.y)
            }
        } else {
            // Hard lock expires
            isHardLocked = false
            lockedTargetID = nil
            framesSinceLockedSeen = 0
            
            DispatchQueue.main.async {
                self.isUsingColorReacquire = false
                self.hardLockCenter = nil
                self.isColorLockActive = false
            }
            
            chosen = pickBestTarget(...)  // Normal scoring
        }
    }
} else {
    // No hard lock – normal scoring-based choice
    framesSinceLockedSeen = 0
    DispatchQueue.main.async {
        self.isUsingColorReacquire = false
    }
    chosen = pickBestTarget(...)
}
```

**Empty Detections Path:**
When no detections are found, the system preserves color lock state:
```swift
guard !detections.isEmpty else {
    // Tracking-wise, we lost them this frame
    DispatchQueue.main.async {
        self.faceCenter = nil
        self.smoothedCenter = nil
        self.allDetections = []
        self.targetBoundingBox = nil
    }
    
    // Keep isHardLocked / isColorLockActive as-is;
    // framesSinceLockedSeen should still be incremented in the outer logic.
    return
}
```

**Reset Behavior:**
```swift
func resetTracking() {
    smoothedCenter = nil
    faceCenter = nil
    currentTargetID = nil
    allDetections = []
    targetBoundingBox = nil
    
    // Reset hard lock state
    isHardLocked = false
    lockedTargetID = nil
    framesSinceLockedSeen = 0
}
```

**Tuning:**
- `hardLockLostThreshold = 20` frames (~1 second at 20 Hz)
- Increase for more persistence through temporary occlusions
- Decrease for faster recovery if subject truly leaves frame

### UI Integration

**iPhone UI (CameraScreen)**
- "Lock Surfer" button calls `requestSubjectLock()`
- Status pill shows "Subject locked ✅" when `hasLockedSubject == true`

**Apple Watch**
- "Lock Surfer" button sends `["lockSubject": true]` via WCSession
- Phone receives message and calls `requestSubjectLock()`

**Callback Wiring (CameraScreen.onAppear)**
```swift
// Wire subject size lock callback (set at runtime to avoid escaping self in init)
faceTracker.onSubjectSizeLocked = { width, height in
    baselineSubjectWidth = width
    baselineSubjectHeight = height
}

// Wire watch lock subject callback
gpsTracker.onLockSubject = {
    requestSubjectLock()
}
```

### Debug Visualization (CameraScreen)

The system provides visual debug overlays to help understand color lock behavior:

**Red Dot (Vision Tracking Center)**
- Shows the current Vision tracking center (`faceCenter`)
- This is what the servos follow
- 18x18 red circle, positioned at the detected person's center

**Blue Ring (Color-Locked Position)**
- Shows where the color-locked/hard-locked logic thinks the subject is (`hardLockCenter`)
- Blue when locked subject is found
- Cyan when in color reacquire mode (`isUsingColorReacquire = true`)
- 22x22 ring (slightly larger than red dot)
- Visible even when the red dot disappears (e.g., during temporary occlusion)

**Color Lock Debug HUD (Top-Right)**
- Shows a color swatch (24x24 rounded rectangle) with the locked color
- Displays RGB text (e.g., "R:210 G:35 B:40") in monospaced font
- Only visible when `isColorLockActive = true`
- Styled with semi-transparent black background

**Implementation:**
```swift
// Blue ring overlay (in GeometryReader)
if faceTracker.isColorLockActive,
   let lockCenter = faceTracker.hardLockCenter {
    let mirroredX = 1 - lockCenter.x
    let xPos = mirroredX * width
    let yPos = (1 - lockCenter.y) * height
    
    Circle()
        .stroke(
            faceTracker.isUsingColorReacquire ? Color.cyan : Color.blue,
            lineWidth: 2
        )
        .frame(width: 22, height: 22)
        .position(x: xPos, y: yPos)
}

// Color lock debug HUD
private var colorLockDebugHud: some View {
    Group {
        if faceTracker.isColorLockActive,
           let uiColor = faceTracker.lockedColorPreview {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor))
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    )
                
                Text(faceTracker.lockedColorDebugText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.45))
            )
        }
    }
}
```

**Visual Behavior:**
- When you hit "Lock Surfer": `isColorLockActive = true`, color swatch appears, RGB label shows (e.g., "R:210 G:35 B:40")
- While locked: Red dot = actual tracking center, Blue ring = "this is the ID/color we are committed to"
- In grace window: `isUsingColorReacquire = true` → blue ring turns cyan, red dot may flicker/vanishing, but blue/cyan marker shows where color-based reacquire is trying to hold on

### Behavior Notes

- **When active**: Color score helps distinguish the locked subject from others
- **When inactive**: `targetColorStrength = 0.0` → color score = 0, no influence
- **Hard Lock**: When subject is locked, the specific detection ID is prioritized above all scoring. System will not switch to another person even if they score higher, as long as the locked target is present.
- **Grace Period**: If locked target disappears, system uses color-heavy reacquire mode (45% color) for up to 20 frames (~1s) before dropping hard lock.
- **Persistence**: Color lock and hard lock survive temporary target loss (duck-dives, falls) during grace period
- **Reset**: Color lock and hard lock cleared on `resetTracking()` or mode switch
- **Performance**: Color sampling runs on Vision queue; minimal overhead

---

## Servo Clamping / Helpers
- `clampAngle` (pan) is in CameraScreen; servo safe range 15–165°.
- `clampTiltAngle` (tilt) is in CameraScreen; servo safe range 80–180° (matches ESP32 tilt limits).
- Legacy GPS servo helpers remain but GPS servo is disabled in code.

### Servo Command Smoothing (AI Path)

AI tracking uses smoothed servo commands for stable movement:

```swift
// PAN (smoothed for AI)
private var lastCommandedPanAngle: CGFloat?
private func sendPanAngle(_ angle: Int) {
    let raw = CGFloat(angle)
    let zoom = zoomController.zoomFactor
    let alpha: CGFloat = zoom >= 4.0 ? 0.55 : 0.7  // 70% weight at normal zoom, 55% at high zoom
    let smoothed = (lastCommandedPanAngle ?? raw) + alpha * (raw - (lastCommandedPanAngle ?? raw))
    lastCommandedPanAngle = smoothed
    api.trackPan(angle: Int(smoothed.rounded()))
}

// TILT (smoothed for AI)
private var lastCommandedTiltAngle: CGFloat?
private func clampTiltAngle(_ angle: CGFloat) -> CGFloat { max(80, min(180, angle)) }
private func sendTiltAngle(_ angle: Int) {
    let raw = CGFloat(angle)
    let zoom = zoomController.zoomFactor
    
    // 🔁 Match pan smoothing: more smoothing at high zoom
    let alpha: CGFloat = zoom >= 4.0 ? 0.55 : 0.7  // 70% weight at normal zoom, 55% at high zoom

    let smoothed: CGFloat
    if let last = lastCommandedTiltAngle {
        smoothed = last + alpha * (raw - last)
    } else {
        smoothed = raw
    }

    let clamped = clampTiltAngle(smoothed)
    lastCommandedTiltAngle = clamped
    api.trackTilt(angle: Int(clamped.rounded()))
    // Note: api.currentTiltAngle is @Published and will update automatically
}
```

### Immediate Servo Commands (Manual Controls)

Manual arrow taps use immediate commands (no smoothing) for instant, crisp response:

```swift
// MARK: - Immediate servo commands for manual controls

private func sendPanAngleImmediate(_ angle: Int) {
    let clamped = clampAngle(CGFloat(angle))
    lastCommandedPanAngle = clamped  // keep smoothing in sync
    api.trackPan(angle: Int(clamped.rounded()))
}

private func sendTiltAngleImmediate(_ angle: Int) {
    let clamped = clampTiltAngle(CGFloat(angle))
    lastCommandedTiltAngle = clamped
    api.trackTilt(angle: Int(clamped.rounded()))
}
```

**Why two paths?**
- **AI path** (smoothed): Prevents jittery movement during automatic tracking
- **Manual path** (immediate): Gives instant feedback when user taps arrows

### Manual Override System

Prevents AI from fighting manual input by pausing AI servo commands for ~0.5s after a manual tap:

```swift
// MARK: - Manual override (prevents AI from fighting manual taps)
@State private var manualOverrideFrames: Int = 0
private let manualOverrideDurationFrames: Int = 10 // ~0.5s at 20Hz

// In trackWithCameraAI():
private func trackWithCameraAI() {
    let hasTarget = (faceTracker.faceCenter != nil)

    // If we recently nudged manually, let Vision "see" but don't move servos.
    if manualOverrideFrames > 0 {
        manualOverrideFrames &-= 1
        // You can still update subjectWidth/auto-zoom if you want:
        if hasTarget {
            updateSubjectWidthAndAutoZoom()
        }
        return
    }

    // ... rest of tracking logic ...
}

// In nudge functions:
private func nudgePan(by delta: CGFloat) {
    let current = CGFloat(api.currentPanAngle)
    let newAngle = clampAngle(current + delta)
    manualOverrideFrames = manualOverrideDurationFrames
    sendPanAngleImmediate(Int(newAngle))
}

private func nudgeTilt(by delta: CGFloat) {
    let current = CGFloat(api.currentTiltAngle)
    let newTilt = clampTiltAngle(current + delta)
    manualOverrideFrames = manualOverrideDurationFrames
    sendTiltAngleImmediate(Int(newTilt))
}
```

**Behavior:**
- Manual tap → instant servo move (no smoothing delay)
- AI paused for 10 frames (~0.5s) so it doesn't fight the manual input
- Vision continues tracking (for auto-zoom, etc.) but doesn't command servos
- After override expires, AI smoothly resumes control

---

## Zoom (for AI)
- `ZoomController` presets: ultraWide05 (0.5x, HFOV 110°), wide1 (1x, 78°), tele2 (2x, 40°), tele4 (4x, 22°).
- AI uses normalized coordinates; zoom does not change math, only apparent FOV and detection quality.
- Lens center bias per preset via `LensCalibrationManager`.
- **Auto-zoom (Vision-based)**: Targets 6% fixed subject width, can drive up to **8.0x** zoom (beyond preset chips). Live zoom readout in UI shows current factor (e.g., "5.3x", "8.0x").

### ZoomController key code (autoDistance + autoSubjectWidth + presets)
```swift
enum ZoomMode: Equatable {
    case fixed(CGFloat)
    case autoSubjectSize      // legacy / unused
    case autoDistance         // GPS-based
    case autoSubjectWidth     // Vision-based width auto zoom
    case off
}

final class ZoomController: ObservableObject {
    @Published private(set) var currentPreset: ZoomPreset = .wide1 {
        didSet { currentHFOV = currentPreset.anchorHFOV }
    }
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var currentHFOV: Double = ZoomPreset.wide1.anchorHFOV
    @Published var mode: ZoomMode = .fixed(1.0) {
        didSet {
            if case .autoSubjectWidth = mode {
                narrowFrames = 0
                wideFrames = 0
            }
        }
    }
    var autoDistanceZoomFloor: CGFloat = 1.5
    private var lastZoomDistanceMeters: Double?
    private var basePresetWhenAutoStarted: ZoomPreset?
    // Persistence counters for autoSubjectWidth
    private var narrowFrames = 0
    private var wideFrames = 0

    func applyPreset(_ preset: ZoomPreset) {
        currentPreset = preset
        mode = .fixed(preset.uiZoomFactor)
        if let device = cameraManager?.videoDevice {
            let deviceFactor = preset.deviceZoomFactor(for: device)
            cameraManager?.setZoom(deviceFactor)
        } else {
            setZoomLevel(preset.uiZoomFactor)
        }
    }

    func updateZoomForDistance(
        distanceMeters: Double?,
        gpsTrust: CGFloat,
        hasGoodGPS: Bool,
        cameraManager: CameraSessionManager
    ) {
        guard case .autoDistance = mode else { return }
        guard hasGoodGPS, gpsTrust >= 0.4, let distance = distanceMeters else { return }
        let distanceDeadband: Double = 2.0
        if let last = lastZoomDistanceMeters, abs(distance - last) < distanceDeadband { return }
        lastZoomDistanceMeters = distance

        let target = targetZoom(for: distance)
        let current = zoomFactor
        let alpha: CGFloat = 0.15
        var newZoom = current + alpha * (target - current)
        let maxDelta: CGFloat = 0.15
        let delta = max(-maxDelta, min(maxDelta, newZoom - current))
        newZoom = current + delta
        if abs(newZoom - current) < 0.01 { return }
        cameraManager.setZoom(newZoom)
        DispatchQueue.main.async { self.zoomFactor = newZoom }
    }

    private func targetZoom(for distanceMeters: Double) -> CGFloat {
        let d = max(0.0, distanceMeters)
        let near = 30.0, mid = 80.0, far = 150.0
        let rawTarget: CGFloat
        if d <= near {
            rawTarget = 1.0
        } else if d <= mid {
            let t = (d - near) / (mid - near)
            rawTarget = 1.0 + CGFloat(t) * 1.0
        } else if d <= far {
            let t = (d - mid) / (far - mid)
            rawTarget = 2.0 + CGFloat(t) * 2.0
        } else {
            rawTarget = 4.0
        }
        let base = basePresetWhenAutoStarted?.uiZoomFactor ?? 1.0
        let floorValue = max(autoDistanceZoomFloor, base)
        let floored = max(floorValue, rawTarget)
        return min(4.0, max(0.5, floored))
    }

    // MARK: - Vision-driven subject-width auto zoom (fixed 6% target)
    /// Adjusts zoom to maintain subject width at 6% of frame (fixed target, not baseline-relative).
    func updateZoomForSubjectWidth(
        normalizedWidth: CGFloat?,
        baselineWidth: CGFloat?,           // now unused; kept for signature compatibility
        cameraManager: CameraSessionManager
    ) {
        guard case .autoSubjectWidth = mode else { return }
        guard let width = normalizedWidth, width > 0.0 else { return }

        // 🎯 Target surfer width = 6% of frame
        let targetWidth: CGFloat = 0.06

        // Deadzone: no zoom change if surfer width is within [5%, 7%]
        let innerTolerance: CGFloat = 0.01   // ±1%

        // Outer band: more aggressive response if > 2% away
        let outerTolerance: CGFloat = 0.02   // ±2%

        let diff = width - targetWidth      // >0 => too big, <0 => too small
        let absDiff = abs(diff)

        // --- Persistence: only act if outside inner band for a few frames ---
        if absDiff > innerTolerance {
            if diff < 0 {
                // surfer too small
                narrowFrames &+= 1
                wideFrames = 0
            } else {
                // surfer too large
                wideFrames &+= 1
                narrowFrames = 0
            }
        } else {
            // In the sweet spot, reset counters and do nothing
            narrowFrames = 0
            wideFrames = 0
            return
        }

        let minTriggerFrames = 5

        if narrowFrames < minTriggerFrames && wideFrames < minTriggerFrames {
            return
        }

        let current = zoomFactor
        var targetZoom = current

        // --- Compute how hard to correct, based on how far we are from target ---
        // Normalized 0..1 "error magnitude" beyond the inner tolerance.
        let excess = max(0.0, absDiff - innerTolerance)
        let normError = min(1.0, excess / outerTolerance) // 0 when barely out of band, 1 when way out

        // Base step size in zoom units per adjustment
        let maxStep: CGFloat = 0.25   // maximum zoom change we *aim* for before smoothing
        let minStep: CGFloat = 0.05   // minimum noticeable correction

        // Interpolate step between minStep and maxStep based on how far off we are
        let stepMagnitude = minStep + (maxStep - minStep) * normError

        if diff < 0 {
            // surfer too small → zoom in
            targetZoom = current + stepMagnitude
        } else {
            // surfer too large → zoom out
            targetZoom = current - stepMagnitude
        }

        // Clamp logical zoom range – this is the hard boundary for auto zoom
        let minFactor: CGFloat = 0.5
        let maxFactor: CGFloat = 8.0   // ✅ new cap at 8x
        targetZoom = max(minFactor, min(maxFactor, targetZoom))

        // --- Smoothing: keep your existing zoom-easing logic ---
        let alpha: CGFloat = 0.25
        var newZoom = current + alpha * (targetZoom - current)

        let baseMaxDeltaPerTick: CGFloat = 0.20
        let zoomSlowdown = 1.0 / (1.0 + 0.3 * max(0.0, current - 4.0))
        let maxDeltaPerTick = baseMaxDeltaPerTick * zoomSlowdown
        let delta = max(-maxDeltaPerTick, min(maxDeltaPerTick, newZoom - current))
        newZoom = current + delta

        if abs(newZoom - current) < 0.01 { return }

        cameraManager.setZoom(newZoom)
        DispatchQueue.main.async { self.zoomFactor = newZoom }
    }
}
```

### LensCalibrationManager (center bias storage)
```swift
final class LensCalibrationManager: ObservableObject {
    static let shared = LensCalibrationManager()
    @Published private var biases: [String: CGFloat] = [:]

    private init() { loadFromDefaults() }

    func bias(for preset: ZoomPreset) -> CGFloat {
        biases[key(for: preset)] ?? 0.0
    }

    func setBias(_ value: CGFloat, for preset: ZoomPreset) {
        biases[key(for: preset)] = value
        UserDefaults.standard.set(Double(value), forKey: key(for: preset))
    }

    func adjustBias(for preset: ZoomPreset, delta: CGFloat) {
        let updated = bias(for: preset) + delta
        setBias(updated, for: preset)
        print("🎯 Updated center bias for \(preset.rawValue): \(updated)°")
    }

    private func key(for preset: ZoomPreset) -> String { "LensCenterBias.\(preset.rawValue)" }
    private func loadFromDefaults() {
        for preset in ZoomPreset.allCases {
            if let stored = UserDefaults.standard.value(forKey: key(for: preset)) as? Double {
                biases[key(for: preset)] = CGFloat(stored)
            }
        }
    }
}
```

### CameraSessionManager (zoom clamping, device selection)
```swift
func setZoom(_ factor: CGFloat) {
    guard let device = videoDevice else { return }
    do {
        try device.lockForConfiguration()
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 24.0) // allow up to 24x if device supports it
        let clamped = max(minZoom, min(factor, maxZoom))
        if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.zoomController?.syncZoomFactorFromDevice(clamped) }
    } catch { print("❌ Zoom error: \(error)") }
}
// Device selection prefers triple -> dual-wide -> wide
```

### ZoomPreset (for reference)
```swift
enum ZoomPreset: String, CaseIterable, Identifiable {
    case ultraWide05, wide1, tele2, tele4
    var displayName: String { ["0.5x","1x","2x","4x"][self.index] } // simplified
    var uiZoomFactor: CGFloat { switch self { case .ultraWide05: return 0.5; case .wide1: return 1; case .tele2: return 2; case .tele4: return 4 } }
    var anchorHFOV: Double { switch self { case .ultraWide05: return 110; case .wide1: return 78; case .tele2: return 40; case .tele4: return 22 } }
    var lensCenterBiasDegrees: CGFloat { LensCalibrationManager.shared.bias(for: self) }
    func deviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let base = device.minAvailableVideoZoomFactor
        switch self {
        case .ultraWide05: return base
        case .wide1:       return base * 2.0
        case .tele2:       return base * 4.0
        case .tele4:       return base * 8.0
        }
    }
}
```

---

## What’s Disabled / Archived
- GPS-driven servo path (`tickGPSServoWithDistanceAndMotion`) is disabled (early return). Archived in `ARCHIVED_GPS_SERVO_LOGIC.md` with full code to restore.
- GPS gating remains available (expectedX flow), but servo movement is AI-only in practice.

---

## Key Entry Points (CameraScreen)
- `trackWithCameraAI()`:
  - **Pan-priority logic**: Tries pan first; only allows tilt if pan didn't move (prevents diagonal "spaz")
  - **Manual override gating**: If `manualOverrideFrames > 0`, Vision tracks but servos don't move
  - calls `applyVisionFollower` (pan) and `applyTiltFollower` (tilt) when a target exists
  - smooths `targetBoundingBox.width` into `smoothedSubjectWidth`
  - gates auto-zoom to:
    - `trackState == .locked`
    - `subjectWidthFrameCounter >= 10` (~0.5s stable)
    - `recoveryMode != .passiveHold`
    - subject centered (abs(faceCenter.x - 0.5) < 0.20)
  - calls `zoomController.updateZoomForSubjectWidth(width, baselineWidth: nil, ...)` (6% fixed target)
  - tracks `framesSinceLastTarget`; no-target frames enter passive hold
- `trackWithGPSAIFusion()`:
  - `.searching`/`.lost`: currently no GPS servo (disabled); Vision can run if face present.
  - `.locked`: Vision-only servo via `applyVisionFollower`; GPS drift telemetry only.
- `tickTracking()` runs at 20 Hz; GPS-triggered ticks also fire via WatchGPSTracker callback.

### CameraScreen Vision auto-zoom integration (code, updated)
```swift
// State
@State private var smoothedSubjectWidth: CGFloat?
@State private var subjectWidthFrameCounter: Int = 0
@State private var subjectWidthHoldFrames: Int = 0
@State private var recoveryMode: RecoveryMode = .none
@State private var framesSinceLastTarget: Int = 0
@State private var manualOverrideFrames: Int = 0
private let passiveHoldFrames: Int = 60 // ~3s at 20 Hz
private let manualOverrideDurationFrames: Int = 10 // ~0.5s at 20 Hz

private func trackWithCameraAI() {
    let hasTarget = (faceTracker.faceCenter != nil)

    // If we recently nudged manually, let Vision "see" but don't move servos.
    if manualOverrideFrames > 0 {
        manualOverrideFrames &-= 1
        if hasTarget {
            updateSubjectWidthAndAutoZoom()
        }
        return
    }

    if hasTarget {
        framesSinceLastTarget = 0
        if recoveryMode == .passiveHold {
            handleReacquiredAfterPassiveHold()
        }

        // 🔥 Pan-priority: try pan first, only allow tilt if pan didn't move
        if let faceCenter = faceTracker.faceCenter {
            let didPanMove = applyVisionFollower(from: faceCenter)
            if !didPanMove {
                _ = applyTiltFollower(from: faceCenter)
            }
        }
        updateSubjectWidthAndAutoZoom()
        return
    } else {
        framesSinceLastTarget &+= 1
        handleNoTargetFrame()
        return
    }
}

private func updateSubjectWidthAndAutoZoom() {
    // 1) Smooth subject width from Vision bbox
    if let bbox = faceTracker.targetBoundingBox {
        let rawWidth = bbox.width
        // Ignore clearly bogus tiny widths
        guard rawWidth > 0.01 else {
            smoothedSubjectWidth = nil
            subjectWidthFrameCounter = 0
            return
        }
        let alpha: CGFloat = 0.4
        if let prev = smoothedSubjectWidth {
            smoothedSubjectWidth = prev * (1 - alpha) + rawWidth * alpha
        } else {
            smoothedSubjectWidth = rawWidth
        }
        subjectWidthFrameCounter &+= 1
        if subjectWidthFrameCounter % 30 == 0, let w = smoothedSubjectWidth {
            print("🔍 Subject width (smoothed): \(String(format: "%.3f", w))")
        }
        subjectWidthHoldFrames = 5 // keep width alive briefly if bbox flickers
    } else {
        subjectWidthFrameCounter = 0
        if subjectWidthHoldFrames > 0 {
            subjectWidthHoldFrames -= 1
        } else {
            smoothedSubjectWidth = nil
        }
    }

    // 2) Vision-driven auto zoom (skip while in passiveHold)
    guard recoveryMode != .passiveHold else { return }
    guard trackState == .locked else { return }
    guard subjectWidthFrameCounter >= 10 else { return }
    if let center = faceTracker.faceCenter {
        let horizontalOffset = abs(center.x - 0.5)
        guard horizontalOffset < 0.20 else { return }
    }

    if let width = smoothedSubjectWidth {
        zoomController.updateZoomForSubjectWidth(
            normalizedWidth: width,
            baselineWidth: nil,          // baseline is unused now (6% fixed target)
            cameraManager: cameraManager
        )
    }
}

// Passive hold helpers
private enum RecoveryMode { case none, passiveHold }

private func handleNoTargetFrame() {
    smoothedSubjectWidth = nil
    switch recoveryMode {
    case .none:
        if framesSinceLastTarget == 1 {
            enterPassiveHold()
        }
    case .passiveHold:
        if framesSinceLastTarget == passiveHoldFrames {
            print("⚠️ Still no surfer after \(passiveHoldFrames) frames (passive hold).")
        }
    }
}

private func enterPassiveHold() {
    recoveryMode = .passiveHold
    zoomModeBeforeHold = zoomController.mode
    zoomBeforeHold = zoomController.zoomFactor
    zoomController.mode = .fixed(zoomController.zoomFactor)
    print("🛑 Entering passive hold (duck-dive / fall recovery).")
}

private func handleReacquiredAfterPassiveHold() {
    recoveryMode = .none
    framesSinceLastTarget = 0
    if case .autoSubjectWidth = zoomModeBeforeHold {
        zoomController.mode = .autoSubjectWidth
    } else {
        zoomController.mode = zoomModeBeforeHold
    }
    print("✅ Reacquired surfer after passive hold.")
}
```

---

## Safety / Limits
- **Pan control**: deadband 0.02 (2% screen width), gain 10, maxStep 4°/tick.
- **Tilt control**: deadband 0.05 (5% screen height, larger for natural bobbing), gain 10, maxStep 4°/tick.
- **Shared control pattern**: Pan and tilt use identical gain/maxStep values and zoom-aware scaling for consistent behavior.
- **Servo angle clamps**: Pan 15–165°, Tilt 80–180°.
- **Center bias**: -0.39° base + lens-specific bias (UserDefaults via LensCalibrationManager).
- **Mirror**: servoMirror = -1.0 (Vision path).

---

## How to Re-enable GPS Servo Later
1) Replace the body of `tickGPSServoWithDistanceAndMotion()` with the archived logic from `ARCHIVED_GPS_SERVO_LOGIC.md`.
2) Decide on direction (keep mirror `* -1.0` or not).
3) Reconnect calls in GPS modes (`trackWithWatchGPS`, gpsAI searching/lost) — currently they call the function, but it early-returns.

---

## Known Integration Points
- Calibration (rig/center) stays active; calibration data still feeds `calibratedBearing`.
- Zoom presets/FOV stay active; AI math remains normalized.
- GPS distance/motion/filtered bearing still computed; just not used for servo.

---

## Quick File Map (AI-relevant)
- `SurfCam/CameraScreen.swift`: AI mode, state machine, Vision follower, clampAngle, bias, mirror.
- `SurfCam/FaceTracker.swift`: Vision detection, smoothing, scoring, gating.
- `SurfCam/GPSHelpers.swift`: bearings, expectedX helpers (for gating), servo mapping (legacy GPS).
- `SurfCam/ZoomController.swift`: presets, FOV, lens bias hook.
- `SurfCam/CameraSessionManager.swift`: camera setup, frame delivery to FaceTracker, zoom clamping.
- `SurfCam/LensCalibrationManager.swift`: per-lens bias storage.

---

# Zoom System (current)

## Presets & FOV
- Presets: `ultraWide05` (0.5x, HFOV 110°), `wide1` (1x, 78°), `tele2` (2x, 40°), `tele4` (4x, 22°).
- GPS uses `currentHFOV` from the active preset (expectedX gating only; GPS servo is disabled).
- Vision uses normalized coords; zoom does not change Vision math, only FOV/quality.

## ZoomController.swift
- Modes: `.fixed(CGFloat)`, `.autoSubjectSize` (legacy), `.autoDistance` (GPS-based), `.autoSubjectWidth` (Vision-based), `.off`.
- Auto-distance:
  - Mapping: 30/80/150 m → 1x/2x/4x (linear), capped at 4x.
  - Floor: max(autoDistanceZoomFloor=1.5x, preset-at-enable), min 0.5x, cap 4x.
  - Smoothing: α=0.15 toward target, maxΔ=0.15x/tick, distance deadband 2 m.
  - Guardrails: requires hasGoodGPS + gpsTrust≥0.4.
- Auto-subject-width (Vision-based):
  - Fixed target: 6% of frame width (not baseline-relative).
  - Dead zone: 5–7% (inner tolerance ±1%) – no zoom change.
  - Outer band: beyond ±2% from target triggers adaptive step sizing.
  - Persistence: requires 5 consecutive frames outside dead zone before acting.
  - Step sizing: adaptive based on error magnitude (0.05–0.25x per adjustment).
  - Smoothing: α=0.25 toward target, maxΔ=0.20x/tick (zoom-aware slowdown), ignores <0.01 changes.
  - Range: logical 0.5–8.0x (device clamp applies).
- Device clamping: CameraSessionManager clamps to device minAvailableVideoZoomFactor … min(maxAvailableVideoZoomFactor, 24x).

## Lens Bias
- `LensCalibrationManager` stores per-preset center bias (degrees). Applied in Vision follower as baseBias + per-lens bias.

## CameraSessionManager.swift (zoom)
- setZoom() clamps to device min/max (cap 24x) and syncs back to ZoomController.
- selects best back camera (triple → dual-wide → wide).

## UI Hooks

### Layout Organization
- **Top-left**: Zoom preset buttons (0.5x, 1x, 2x, 4x) + live zoom readout (shows up to 8.0x) + "Tracking On/Off" mode button
- **Top row**: Recording indicator, resolution toggle, tracking status indicator
- **Top-right**: Color lock debug HUD (color swatch + RGB text)
- **Bottom row**: Auto Zoom button, Lock Surfer button, subject lock pill, Record button, System panel toggle
- **Bottom-right**: Manual pan/tilt control pad (arrow buttons)

### Controls

**Mode Toggle Button:**
```swift
// MARK: - Mode Toggle
private var modeButton: some View {
    Button(action: toggleTrackingMode) {
        Text(trackingMode == .off ? "Tracking Off" : "Tracking On")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}

private func toggleTrackingMode() {
    switch trackingMode {
    case .off:
        trackingMode = .cameraAI
    default:
        trackingMode = .off
    }
}
```

**Zoom Buttons with Live Readout:**
```swift
private var zoomButtons: some View {
    HStack(spacing: 8) {
        ForEach(ZoomPreset.allCases) { preset in
            Button {
                zoomController.applyPreset(preset)
            } label: {
                Text(preset.displayName)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        zoomController.currentPreset == preset
                        ? Color.white.opacity(0.9)
                        : Color.black.opacity(0.4)
                    )
                    .foregroundColor(
                        zoomController.currentPreset == preset
                        ? .black
                        : .white
                    )
                    .cornerRadius(12)
            }
        }
        
        // Live zoom readout (shows 5.3x, 7.9x, 8.0x, etc.)
        Text(String(format: "%.1fx", zoomController.zoomFactor))
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.4))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}
```

**Control Summary:**
- **Zoom preset buttons**: Call `zoomController.applyPreset()` for each preset (0.5x, 1x, 2x, 4x)
- **Live zoom readout**: Shows current `zoomController.zoomFactor` (e.g., "5.3x", "8.0x") - visible when auto-zoom drives beyond presets
- **Mode button**: Simple "Tracking On/Off" toggle - switches between `.off` and `.cameraAI` modes (GPS/AI+ modes removed from UI)
- **Auto Zoom button**: Toggles `ZoomMode.autoSubjectWidth` (Vision-based, 6% fixed target, up to 8x)
- **"Lock Surfer" button** (iPhone UI): Calls `requestSubjectLock()` → sets `faceTracker.shouldLockSubject = true`
- **"Lock Surfer" button** (Apple Watch): Sends `["lockSubject": true]` via WCSession → triggers `requestSubjectLock()` on phone
- **Subject lock status pill**: Shows "Subject locked ✅" when `hasLockedSubject == true`

### Debug Visualization
- **Red dot (18x18)**: Current Vision tracking center (`faceCenter`) - what servos follow
- **Blue ring (22x22)**: Color-locked position (`hardLockCenter`) - blue when locked, cyan when in reacquire mode
- **Color swatch + RGB HUD (top-right)**: Shows locked color preview and RGB text (e.g., "R:210 G:35 B:40") when `isColorLockActive = true`

## Manual Pan/Tilt Control Pad

A manual control pad overlay allows instant manual adjustment of pan and tilt angles for debugging and fine-tuning. The pad appears at the **bottom-right** of the screen in landscape mode.

### Implementation (CameraScreen)

**Nudge Helpers (with immediate commands + manual override):**
```swift
// MARK: - Manual nudge controls

private let manualPanStep: CGFloat = 3.0     // degrees per tap
private let manualTiltStep: CGFloat = 3.0    // degrees per tap

private func nudgePan(by delta: CGFloat) {
    let current = CGFloat(api.currentPanAngle)
    let newAngle = clampAngle(current + delta)    // still respects 15–165°
    manualOverrideFrames = manualOverrideDurationFrames  // pause AI for ~0.5s
    sendPanAngleImmediate(Int(newAngle))  // instant, no smoothing
}

private func nudgeTilt(by delta: CGFloat) {
    let current = CGFloat(api.currentTiltAngle)
    let newTilt = clampTiltAngle(current + delta) // still respects 80–180°
    manualOverrideFrames = manualOverrideDurationFrames  // pause AI for ~0.5s
    sendTiltAngleImmediate(Int(newTilt))  // instant, no smoothing
}
```

**UI Pad (tighter styling):**
```swift
private var manualControlPad: some View {
    VStack(spacing: 6) {
        Button(action: {
            nudgeTilt(by: -manualTiltStep)   // negative = tilt up (toward horizon)
        }) {
            Image(systemName: "chevron.up.circle.fill")
                .font(.system(size: 26, weight: .bold))
        }
        
        HStack(spacing: 18) {
            Button(action: {
                nudgePan(by: -manualPanStep)  // negative = pan left
            }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 26, weight: .bold))
            }
            
            Button(action: {
                nudgePan(by: manualPanStep)   // positive = pan right
            }) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 26, weight: .bold))
            }
        }
        
        Button(action: {
            nudgeTilt(by: manualTiltStep)     // positive = tilt down (toward beach)
        }) {
            Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 26, weight: .bold))
        }
    }
    .padding(10)
    .background(
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.black.opacity(0.35))
    )
    .foregroundColor(.white)
}
```

**Positioning (in GeometryReader ZStack):**
```swift
// Bottom-right: Manual pan/tilt control pad
manualControlPad
    .padding(.trailing, 24)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
```

**Behavior:**
- **Instant response**: Uses `sendPanAngleImmediate` / `sendTiltAngleImmediate` (no smoothing delay)
- **Manual override**: Sets `manualOverrideFrames = 10` (~0.5s) to pause AI servo commands after tap
- **AI continues tracking**: Vision still tracks (for auto-zoom, etc.) but servos don't move during override
- **Each tap adjusts by 3°**: Configurable via `manualPanStep` / `manualTiltStep`
- **Respects servo limits**: pan 15–165°, tilt 80–180°
- **Positioned at bottom-right**: Clean placement in landscape mode, doesn't interfere with other controls
- **Tighter styling**: Smaller spacing (6px vertical, 18px horizontal), smaller icons (26pt), tighter padding (10px)

## Disabled / Archived (Zoom + GPS Servo)
- GPS servo path is disabled in code; archived in `ARCHIVED_GPS_SERVO_LOGIC.md`.
- AutoSubjectSize logic exists but is not invoked in the tracking loop.

---

This document captures the full AI tracking behavior as of now, with GPS servo disabled for rework. Use it as the source of truth when refactoring or re-enabling GPS-driven movement.

