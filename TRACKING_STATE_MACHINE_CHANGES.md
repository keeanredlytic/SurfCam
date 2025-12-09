# Tracking State Machine Implementation

This document contains all the code changes for implementing the tracking state machine that gives Vision full control when locked, while using GPS fusion during searching and lost states.

---

## Table of Contents

1. [Step 1: TrackState Enum & State Variables](#step-1-trackstate-enum--state-variables)
2. [Step 2: State Machine Update Logic](#step-2-state-machine-update-logic)
3. [Step 3: Refactored GPS+AI Tracking](#step-3-refactored-gpsai-tracking)
4. [Step 4: Integration Points](#step-4-integration-points)
5. [Step 5: GPS Trust Metrics (Telemetry)](#step-5-gps-trust-metrics-telemetry)
6. [Step 6: GPS-First Fusion Logic](#step-6-gps-first-fusion-logic)

---

## Step 1: TrackState Enum & State Variables

### 1.1 Add TrackState Enum

**Location:** Add this enum right after `TrackingMode` enum in `CameraScreen.swift`

```swift
enum TrackState {
    case searching   // trying to find the surfer
    case locked      // strong visual lock – Vision rules
    case lost        // just lost them – rely on GPS to reacquire
}
```

### 1.2 Add State Variables to CameraScreen

**Location:** Add these `@State` variables in the `CameraScreen` struct, after your existing state variables

```swift
// MARK: - Tracking State Machine
@State private var trackState: TrackState = .searching
@State private var consecutiveLockFrames: Int = 0  // How many consecutive frames we've had a good vision lock
@State private var consecutiveLostFrames: Int = 0  // How many consecutive frames we've had no vision detection

// Thresholds (tweakable)
private let lockFramesThreshold = 12    // ~1.2s at 10Hz
private let lostFramesThreshold = 8     // ~0.8s at 10Hz
```

---

## Step 2: State Machine Update Logic

### 2.1 Update `tickTracking()` Method

**Location:** Replace your existing `tickTracking()` method with this version

```swift
// MARK: - Tracking dispatch

private func tickTracking() {
    guard trackingMode != .off else { return }
    
    // Check if we have a vision target
    let hasVisionTarget = (faceTracker.faceCenter != nil)
    
    // Update high-level track state (only for AI modes)
    if trackingMode == .cameraAI || trackingMode == .gpsAI {
        updateTrackState(hasVisionTarget: hasVisionTarget)
    }
    
    // Dispatch to appropriate tracking method
    switch trackingMode {
    case .off:
        return
    case .cameraAI:
        trackWithCameraAI()
    case .watchGPS:
        trackWithWatchGPS()
    case .gpsAI:
        trackWithGPSAIFusion()
    }
}
```

### 2.2 Add `updateTrackState()` Method

**Location:** Add this method in the tracking section of `CameraScreen`

```swift
// MARK: - Tracking State Machine

/// Update the tracking state based on vision detection
private func updateTrackState(hasVisionTarget: Bool) {
    switch trackState {
    case .searching:
        if hasVisionTarget {
            consecutiveLockFrames += 1
            consecutiveLostFrames = 0
            
            if consecutiveLockFrames >= lockFramesThreshold {
                trackState = .locked
                print("🔒 Entering LOCKED state")
            }
        } else {
            consecutiveLockFrames = 0
            consecutiveLostFrames += 1
            // We can stay in .searching indefinitely here
        }
        
    case .locked:
        if hasVisionTarget {
            // Keep lock solid
            consecutiveLostFrames = 0
        } else {
            consecutiveLostFrames += 1
            
            if consecutiveLostFrames >= lostFramesThreshold {
                trackState = .lost
                consecutiveLockFrames = 0
                print("❗️ Lost target – entering LOST state")
            }
        }
        
    case .lost:
        if hasVisionTarget {
            // Found someone again – go back to searching first
            // then quickly promote to locked if continuity is good
            trackState = .searching
            consecutiveLockFrames = 1
            consecutiveLostFrames = 0
            print("🔍 Vision reacquired – back to SEARCHING")
        } else {
            // Still lost – GPS will drive the search
            consecutiveLostFrames += 1
        }
    }
}
```

### 2.3 Reset State on Mode Switch

**Location:** In your `.onChange(of: trackingMode)` handler, add this reset logic

```swift
// Reset tracking state machine when switching modes
if newMode == .cameraAI || newMode == .gpsAI {
    trackState = .searching
    consecutiveLockFrames = 0
    consecutiveLostFrames = 0
}
```

**Also reset when turning tracking off:**

```swift
} else {
    // Off mode
    stopTrackingTimer()
    // Reset state machine when turning off
    trackState = .searching
    consecutiveLockFrames = 0
    consecutiveLostFrames = 0
}
```

**Full context of where this goes:**

```swift
.onChange(of: trackingMode) { _, newMode in
    // ... existing mode switching logic ...
    
    if newMode == .cameraAI {
        // ... AI mode setup ...
    } else if newMode == .watchGPS {
        // ... GPS mode setup ...
    } else if newMode == .gpsAI {
        // ... GPS+AI mode setup ...
    } else {
        // Off mode
        stopTrackingTimer()
        // Reset state machine when turning off
        trackState = .searching
        consecutiveLockFrames = 0
        consecutiveLostFrames = 0
    }
    
    // Reset tracking state machine when switching modes
    if newMode == .cameraAI || newMode == .gpsAI {
        trackState = .searching
        consecutiveLockFrames = 0
        consecutiveLostFrames = 0
    }
}
```

---

## Step 3: Refactored GPS+AI Tracking

### 3.1 Replace `trackWithGPSAIFusion()` Method

**Location:** Replace your existing `trackWithGPSAIFusion()` method with this state-based version

```swift
// MARK: - GPS+AI Fusion Tracking

private func trackWithGPSAIFusion() {
    let hasVisionTarget = (faceTracker.faceCenter != nil)
    
    switch trackState {
    case .searching:
        gpsAiSearchingTick(hasVisionTarget: hasVisionTarget)
        
    case .locked:
        gpsAiLockedTick(hasVisionTarget: hasVisionTarget)
        
    case .lost:
        gpsAiLostTick(hasVisionTarget: hasVisionTarget)
    }
}
```

### 3.2 Update `trackWithCameraAI()` to Use Shared Vision Follower

**Location:** Replace your existing `trackWithCameraAI()` method

```swift
// MARK: - Camera AI tracking (Vision-based)

private func trackWithCameraAI() {
    guard let faceCenter = faceTracker.faceCenter else { return }
    applyVisionFollower(from: faceCenter)
}
```

### 3.3 Add State-Specific Tracking Methods

**Location:** Add these three methods after `trackWithGPSAIFusion()`

```swift
// MARK: - GPS+AI State-Specific Tracking

/// Searching state: Use GPS fusion to find and acquire target
private func gpsAiSearchingTick(hasVisionTarget: Bool) {
    // This uses the existing GPS fusion logic:
    // - compute expectedXFromGPS
    // - if in FOV, set expectedX on faceTracker, use GPS gating
    // - if Vision finds person, start tracking with AI-like logic
    // - if not, pan toward expectedX
    runExistingGPSAIBehavior()
}

/// Locked state: Vision has full control - GPS does NOT move the servo
private func gpsAiLockedTick(hasVisionTarget: Bool) {
    guard hasVisionTarget, let faceCenter = faceTracker.faceCenter else {
        // No vision in locked? The state machine will push us to .lost soon.
        // For now, do nothing — trackState will transition on next tick.
        return
    }
    
    // ✅ Vision-only horizontal tracking (same as classic AI follower)
    applyVisionFollower(from: faceCenter)
}

/// Lost state: Use GPS to reacquire target
private func gpsAiLostTick(hasVisionTarget: Bool) {
    // At the moment, this can just reuse the "searching" logic.
    // Later we'll add expanding search cones, etc.
    runExistingGPSAIBehavior()
}
```

### 3.3 Add Helper: Existing GPS+AI Behavior

**Location:** Add this method to extract the existing GPS fusion logic

```swift
// MARK: - Helper: Existing GPS+AI Behavior (for searching/lost states)

/// Runs the existing GPS+AI fusion logic (used in searching and lost states)
private func runExistingGPSAIBehavior() {
    // Step 1: Compute expected screen X from GPS
    let expectedX = computeExpectedXFromGPS()
    gpsExpectedX = expectedX
    faceTracker.expectedX = expectedX
    
    // Step 2: Check if Vision found a target
    let hasVisionTarget = faceTracker.faceCenter != nil
    
    if let expX = expectedX {
        // GPS says target should be in FOV
        
        if hasVisionTarget {
            // ✅ Vision found someone - track with AI (GPS-gated selection already applied)
            trackWithCameraAI()
        } else {
            // ⚠️ GPS says in-frame but Vision can't see them
            // Gently pan toward where GPS says they should be
            panTowardExpectedX(expX)
        }
    } else {
        // GPS says target is outside FOV
        // Use pure GPS tracking to rotate toward them
        if gpsTracker.isReceiving {
            trackWithWatchGPS()
        }
    }
}
```

### 3.4 Add Shared Vision Follower Function

**Location:** Add this shared function to ensure coordinate consistency

```swift
// MARK: - Vision Follower (Shared Logic)

/// Shared vision-based servo control used by both AI mode and GPS+AI locked state
/// Ensures coordinate consistency across all Vision tracking modes
private func applyVisionFollower(from faceCenter: CGPoint) {
    // Use non-mirrored X for consistent coordinate system
    // Vision coordinates: 0..1, left→right
    let x = faceCenter.x                     // 0..1 (already normalized Vision coord)
    let offset = x - 0.5                     // -0.5..+0.5
    
    let deadband: CGFloat = 0.10            // 10% of screen
    if abs(offset) < deadband { return }     // no servo command if near center
    
    let gain: CGFloat = 8.0                 // converts offset to angle change
    var step = offset * gain                // degrees left/right
    
    let maxStep: CGFloat = 4.0
    if step > maxStep { step = maxStep }
    if step < -maxStep { step = -maxStep }
    
    let currentAngle = CGFloat(api.currentAngle)
    let newAngle = clampAngle(currentAngle + step)
    sendServoAngle(Int(newAngle))
}
```

### 3.5 Add Servo Control Helpers

**Location:** Add these helper methods for servo control

```swift
// MARK: - Servo Control Helpers

/// Clamp servo angle to valid range (15°-165° to avoid physical limits)
private func clampAngle(_ angle: CGFloat) -> CGFloat {
    let minAngle: CGFloat = 15.0
    let maxAngle: CGFloat = 165.0
    return max(minAngle, min(maxAngle, angle))
}

/// Send servo angle command and update tracked angle
private func sendServoAngle(_ angle: Int) {
    // Use existing PanRigAPI.track(angle:)
    api.track(angle: angle)
    // Note: api.currentAngle is @Published and will update automatically
}
```

**Important:** Also update `panTowardExpectedX()` to use these helpers:

```swift
/// Gently pan toward where GPS says the target should be
private func panTowardExpectedX(_ expectedX: CGFloat) {
    // Expected X is 0..1 where 0.5 is center
    // We want to pan so that expectedX moves toward 0.5
    
    let offset = expectedX - 0.5  // -0.5 to +0.5
    
    // Small deadband
    if abs(offset) < 0.05 { return }
    
    // Slow movement when searching
    let gain: Double = 2.0
    let maxStep: Double = 2.0
    
    let rawStep = Double(offset) * gain
    let step = max(-maxStep, min(maxStep, rawStep))
    
    let newAngle = clampAngle(CGFloat(api.currentAngle) + CGFloat(step))
    sendServoAngle(Int(newAngle))
}
```

---

## Step 4: Integration Points

### 4.1 Complete Code Structure

Here's the complete structure showing where everything fits:

```swift
struct CameraScreen: View {
    // ... existing properties ...
    
    // MARK: - Tracking State Machine
    @State private var trackState: TrackState = .searching
    @State private var consecutiveLockFrames: Int = 0
    @State private var consecutiveLostFrames: Int = 0
    private let lockFramesThreshold = 12
    private let lostFramesThreshold = 8
    
    // ... rest of your view code ...
    
    // MARK: - Tracking dispatch
    private func tickTracking() {
        // ... state machine integration ...
    }
    
    // MARK: - Tracking State Machine
    private func updateTrackState(hasVisionTarget: Bool) {
        // ... state transitions ...
    }
    
    // MARK: - GPS+AI Fusion Tracking
    private func trackWithGPSAIFusion() {
        // ... state-based routing ...
    }
    
    // MARK: - GPS+AI State-Specific Tracking
    private func gpsAiSearchingTick(hasVisionTarget: Bool) { ... }
    private func gpsAiLockedTick(hasVisionTarget: Bool) { ... }
    private func gpsAiLostTick(hasVisionTarget: Bool) { ... }
    
    // MARK: - Helper: Existing GPS+AI Behavior
    private func runExistingGPSAIBehavior() { ... }
    
    // MARK: - Servo Control Helpers
    private func clampAngle(_ angle: CGFloat) -> CGFloat { ... }
    private func sendServoAngle(_ angle: Int) { ... }
}
```

---

## Key Behavior Changes

### Before State Machine
- GPS and Vision both could move the servo in GPS+AI mode
- No distinction between "searching", "locked", or "lost" states
- GPS always had influence on servo movement

### After State Machine

#### `.searching` State
- Uses existing GPS fusion logic
- GPS can move the servo to help find target
- Vision detection with GPS gating for person selection

#### `.locked` State ⭐ **NEW BEHAVIOR**
- **Vision has 100% control** - GPS does NOT move the servo
- Pure Vision-based tracking (same as classic AI mode)
- GPS still participates in selection/gating, but no movement
- Ensures smooth, responsive tracking once lock is established

#### `.lost` State
- Uses GPS to reacquire target
- GPS can move the servo to search
- Will transition back to `.searching` when Vision reacquires

---

## State Transition Logic

```
SEARCHING → LOCKED
  - After 12 consecutive frames with vision target
  - Logs: "🔒 Entering LOCKED state"

LOCKED → LOST
  - After 8 consecutive frames without vision target
  - Logs: "❗️ Lost target – entering LOST state"

LOST → SEARCHING
  - When vision target is reacquired
  - Logs: "🔍 Vision reacquired – back to SEARCHING"
  - Starts with consecutiveLockFrames = 1 (quick path to locked)
```

---

## Configuration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `lockFramesThreshold` | 12 frames | Frames needed to transition searching → locked (~1.2s at 10Hz) |
| `lostFramesThreshold` | 8 frames | Frames needed to transition locked → lost (~0.8s at 10Hz) |
| Deadband (vision follower) | 10% | Don't move servo if within 10% of center |
| Gain (vision follower) | 8.0 | Converts offset to angle change |
| Max Step (vision follower) | 4.0° | Maximum angle change per tick |
| Min Servo Angle | 15° | Minimum safe servo angle (avoids physical limits) |
| Max Servo Angle | 165° | Maximum safe servo angle (avoids physical limits) |

---

## Testing Checklist

- [ ] State transitions work correctly (searching → locked → lost)
- [ ] Console logs appear for state transitions
- [ ] In `.locked` state, GPS does not move the servo
- [ ] In `.locked` state, Vision controls servo smoothly
- [ ] State resets when switching tracking modes
- [ ] State resets when turning tracking off
- [ ] `.searching` and `.lost` states still use GPS fusion
- [ ] AI mode and locked mode use identical coordinate system (no sudden flips)
- [ ] Servo angles are clamped to 15-165° range (not 0-180°)
- [ ] All angle calculations use `clampAngle()` helper consistently

---

## Critical Fixes Applied

### ✅ Coordinate Consistency
- **Issue:** AI mode and locked mode used different coordinate systems (mirrored vs non-mirrored)
- **Fix:** Created shared `applyVisionFollower()` function used by both `trackWithCameraAI()` and `gpsAiLockedTick()`
- **Result:** No coordinate system mismatches or sudden flips when transitioning states

### ✅ Angle Clamping Range
- **Issue:** Initial implementation used 0-180° range
- **Fix:** Changed to 15-165° range to avoid physical limits and wiring collisions
- **Result:** Consistent with existing working build, prevents hardware damage

### ✅ State Reset on Off
- **Issue:** State counters could carry over when turning tracking off
- **Fix:** Added state reset when `trackingMode == .off`
- **Result:** Clean state when restarting tracking

### ✅ Servo Angle Source
- **Status:** Using `api.currentAngle` which is `@Published var currentAngle: Double` in `PanRigAPI`
- **Note:** This is the correct source of truth - no changes needed

## Notes

- The state machine only runs for `.cameraAI` and `.gpsAI` modes
- `.watchGPS` mode is unaffected (pure GPS tracking)
- State resets to `.searching` when switching modes or turning off
- All existing GPS fusion logic is preserved in `runExistingGPSAIBehavior()`
- The `.locked` state ensures Vision has full control once a strong lock is established
- **Coordinate system is now consistent** - both AI mode and locked mode use the same `applyVisionFollower()` function
- **All angle clamping uses 15-165° range** for safety

---

---

## Step 5: GPS Trust Metrics (Telemetry)

### 5.1 Add GPS Quality State Variables

**Location:** Add these after the tracking state machine variables in `CameraScreen`

```swift
// MARK: - GPS Quality Metrics (Vision vs GPS alignment)
@State private var gpsBias: CGFloat = 0.0          // running average (gpsX - visionX)
@State private var gpsErrorRMS: CGFloat = 0.0      // running RMS of error
@State private var gpsSampleCount: Int = 0         // how many samples we've accumulated

// Smoothing / scaling constants for GPS trust
private let gpsEMAAlpha: CGFloat = 0.05           // smaller = smoother, larger = more reactive
private let gpsMaxScreenErrorForTrust: CGFloat = 0.25  // ~25% of screen width treated as "very bad"
private let gpsMinSamplesForTrust: Int = 30        // need at least this many samples before trusting
```

### 5.2 Add Computed GPS Trust Property

**Location:** Add this computed property after the GPS quality metrics variables

```swift
// MARK: - Derived GPS Trust Score (0 = trash, 1 = very reliable)

/// Computed GPS trust score based on alignment between GPS predictions and Vision detections
/// Returns 0.0 if not enough samples, otherwise 0.0-1.0 where 1.0 = perfect alignment
private var gpsTrust: CGFloat {
    // Not enough data yet → no trust
    guard gpsSampleCount >= gpsMinSamplesForTrust else { return 0.0 }
    
    // Error component: 1 when error ≈ 0, goes toward 0 as RMS error grows
    // gpsErrorRMS is in normalized screen units [0..1] where 0.5 = half screen width
    let normalizedError = gpsErrorRMS / gpsMaxScreenErrorForTrust
    let errorComponent = max(0.0, 1.0 - normalizedError)  // clamp to [0, 1]
    
    // You can incorporate more components later (e.g., GPS accuracy, latency).
    // For now, gpsTrust == errorComponent
    return errorComponent
}
```

### 5.3 Add GPS Quality Metrics Updater Function

**Location:** Add this function after the tracking state machine methods, before GPS+AI fusion methods

```swift
// MARK: - GPS Quality Metrics Updater

/// Call this when we have BOTH a reliable Vision center and a GPS-predicted expectedX.
/// This updates:
///  - gpsBias: average (gpsX - visionX)
///  - gpsErrorRMS: RMS error magnitude
///  - gpsSampleCount: number of samples
///
/// NOTE: This is telemetry-only. It does NOT change any tracking behavior yet.
private func updateGPSQualityMetrics(faceCenter: CGPoint, expectedX: CGFloat) {
    // Vision X and GPS X are both 0..1 in screen space (left→right).
    let visionX = faceCenter.x
    let gpsX = expectedX
    
    // Signed error: positive means GPS thinks target is more to the right than Vision.
    let error = gpsX - visionX
    
    // Convert to CGFloat (already is) and absolute error magnitude.
    let absError = abs(error)
    
    // Exponential moving average update for bias and RMS.
    //
    // gpsEMAAlpha controls how quickly we adapt:
    //   - small alpha (~0.05) = smoother, slower adaptation
    //   - large alpha (~0.2)  = more reactive, but noisier
    let alpha = gpsEMAAlpha
    let oneMinusAlpha = 1.0 - alpha
    
    // Update running bias (signed)
    gpsBias = oneMinusAlpha * gpsBias + alpha * error
    
    // Update running RMS error:
    // We approximate RMS with EMA of squared error, then take sqrt.
    let prevRMS = gpsErrorRMS
    let prevVarApprox = prevRMS * prevRMS
    let newVarApprox = oneMinusAlpha * prevVarApprox + alpha * (absError * absError)
    gpsErrorRMS = sqrt(newVarApprox)
    
    // Increment sample count (used to gate trust at low sample counts)
    gpsSampleCount += 1
    
    // Optional: debug log (you can comment this out later when stable)
    if gpsSampleCount % 30 == 0 { // log every ~30 samples to avoid spam
        let biasStr = String(format: "%.3f", gpsBias)
        let rmsStr  = String(format: "%.3f", gpsErrorRMS)
        let trustStr = String(format: "%.2f", gpsTrust)
        print("📡 GPS Quality – samples=\(gpsSampleCount) bias=\(biasStr) rms=\(rmsStr) trust=\(trustStr)")
    }
}
```

### 5.4 Integrate Metrics Updater in Locked State

**Location:** Update `gpsAiLockedTick()` to call the metrics updater

```swift
/// Locked state: Vision has full control - GPS does NOT move the servo
private func gpsAiLockedTick(hasVisionTarget: Bool) {
    guard hasVisionTarget, let faceCenter = faceTracker.faceCenter else {
        // No vision in locked? The state machine will push us to .lost soon.
        // For now, do nothing — trackState will transition on next tick.
        return
    }
    
    // 1) Update GPS quality metrics if we have an expectedX from GPS.
    //    This does NOT move the servo or change behavior yet – just telemetry.
    if let expectedX = gpsExpectedX {
        updateGPSQualityMetrics(faceCenter: faceCenter, expectedX: expectedX)
    }
    
    // 2) Vision-only horizontal tracking (same as classic AI follower)
    applyVisionFollower(from: faceCenter)
}
```

### 5.5 Reset Metrics on Mode Changes

**Location:** Update the `.onChange(of: trackingMode)` handler to reset GPS metrics

```swift
.onChange(of: trackingMode) { _, newMode in
    // ... existing mode switching logic ...
    
    } else {
        // Off mode
        stopTrackingTimer()
        trackState = .searching
        consecutiveLockFrames = 0
        consecutiveLostFrames = 0
        
        // Optional: reset GPS quality metrics on full stop
        gpsBias = 0.0
        gpsErrorRMS = 0.0
        gpsSampleCount = 0
    }
    
    // Reset tracking state machine when switching modes
    if newMode == .cameraAI || newMode == .gpsAI {
        trackState = .searching
        consecutiveLockFrames = 0
        consecutiveLostFrames = 0
    }
    
    // Reset GPS metrics when leaving GPS+AI mode
    if newMode != .gpsAI {
        gpsBias = 0.0
        gpsErrorRMS = 0.0
        gpsSampleCount = 0
    }
}
```

### 5.6 What You'll See

After implementing Step 1 (telemetry only), you'll see console logs when in GPS+AI mode and `.locked` state:

```
📡 GPS Quality – samples=30 bias=0.042 rms=0.065 trust=0.74
📡 GPS Quality – samples=60 bias=0.038 rms=0.058 trust=0.77
```

**Interpretation:**
- **bias** ≈ average (gpsX - visionX):
  - > 0 → GPS thinks target is more to the right than Vision does
  - < 0 → GPS thinks target is more to the left
- **rms** ≈ how "jittery" / inaccurate GPS is in normalized screen units:
  - 0.05 ≈ 5% of screen width typical deviation
  - 0.20 ≈ 20% of screen width = bad
- **trust**:
  - near 1 → GPS is very aligned with Vision
  - near 0 → GPS is either very noisy or far off (or not enough samples yet)

### 5.7 Important Notes

- **Zero behavior change** - This is telemetry only
- Metrics only update when in `.locked` state with both Vision and GPS data
- Metrics reset when leaving GPS+AI mode or turning tracking off
- `gpsTrust` will be used in future steps for dynamic gating and bias correction

---

---

## Step 6: GPS-First Fusion Logic

### Overview
This step implements **GPS-first fusion** where GPS drives the servo in searching/lost states, and Vision only takes control when aligned with GPS predictions. The locked state also includes a drift fail-safe that monitors long-term disagreement between Vision and GPS.

### 6.1 Add Fusion Constants & Counters

**Location:** Add these constants and state variable near other GPS/state variables in `CameraScreen.swift`

```swift
// MARK: - GPS + Vision Fusion Constants
/// When searching: how close Vision.x must be to GPS-predicted X (0–1) to accept a person
private let visionGpsMatchThreshold: CGFloat = 0.08     // ~8% of screen width
/// When locked: how far Vision.x is allowed to drift from GPS before we get suspicious
private let visionGpsDriftThreshold: CGFloat = 0.30     // ~30% of screen width
/// How many consecutive "bad drift" frames before we drop Vision lock
private let visionGpsDriftFrameLimit: Int = 15          // ~1.5s at 10Hz
/// Counter for drift frames in locked state
@State private var visionGpsDriftFrames: Int = 0
```

### 6.2 Add GPS Reliability Helper

**Location:** Add this helper function near `updateGPSQualityMetrics()` in `CameraScreen.swift`

```swift
// MARK: - GPS Reliability Helper

/// Returns true when GPS is fresh and aligns reasonably with Vision over time.
private func hasGoodGPS() -> Bool {
    // Basic freshness check from your Watch tracker
    guard gpsTracker.isReceiving else { return false }
    
    // If you have gpsTrust from the telemetry section, use it:
    // (0 = trash, 1 = great; tweak 0.5–0.7 as needed)
    if gpsSampleCount >= gpsMinSamplesForTrust {
        return gpsTrust > 0.6
    }
    
    // Early in a session, before we have enough samples, just trust "freshness".
    return true
}
```

### 6.3 Replace runExistingGPSAIBehavior() with GPS-First Logic

**Location:** Replace the entire `runExistingGPSAIBehavior()` function body

```swift
// MARK: - Helper: GPS-first behavior for SEARCHING / LOST

/// In .gpsAI mode while in .searching or .lost:
/// - If GPS is good → servo driven by GPS only
/// - If Vision sees someone aligned with GPS → Vision takes over
/// - If GPS is bad → fall back to Vision if available
private func runExistingGPSAIBehavior() {
    // 1) Compute GPS-predicted expectedX in screen space (0..1) if in FOV
    let expectedX = computeExpectedXFromGPS()
    gpsExpectedX = expectedX
    faceTracker.expectedX = expectedX  // keeps your GPS-gating behavior intact
    
    let goodGPS    = hasGoodGPS()
    let hasVision  = (faceTracker.faceCenter != nil)
    
    // 2) If GPS is not usable, just fall back to Vision if we have it.
    guard goodGPS else {
        if hasVision {
            trackWithCameraAI()
        }
        return
    }
    
    // From here on, GPS is "good"
    
    // 3) If we have both GPS expectedX (in FOV) AND a Vision target:
    if let gx = expectedX, let fx = faceTracker.faceCenter?.x {
        let diff = abs(fx - gx)
        if diff < visionGpsMatchThreshold {
            // ✅ Vision + GPS agree → let Vision servo take over.
            // State machine will promote us to .locked after enough frames.
            trackWithCameraAI()
            return
        } else {
            // Vision sees someone but not aligned with GPS yet.
            // Treat GPS as the source of truth while searching.
            trackWithWatchGPS()
            return
        }
    }
    
    // 4) GPS is good but either:
    //    - no Vision target, or
    //    - GPS says outside FOV (expectedX == nil)
    // In both cases, we just use GPS-only.
    trackWithWatchGPS()
}
```

**Key Changes:**
- GPS quality check first (`hasGoodGPS()`)
- If GPS is bad, fall back to Vision-only
- If GPS is good, check Vision-GPS alignment
- Only let Vision take control if aligned within 8% threshold
- Otherwise, GPS drives the servo

### 6.4 Add Drift Fail-Safe to Locked State

**Location:** Replace `gpsAiLockedTick(hasVisionTarget:)` function

```swift
/// Locked state: Vision has full control - GPS does NOT move the servo,
/// but we watch for long-term disagreement vs GPS and can drop lock.
private func gpsAiLockedTick(hasVisionTarget: Bool) {
    guard hasVisionTarget, let faceCenter = faceTracker.faceCenter else {
        // No vision this frame; state machine will eventually move us to .lost
        return
    }
    
    // 1) Update GPS telemetry if we have an expectedX
    if let expectedX = gpsExpectedX {
        updateGPSQualityMetrics(faceCenter: faceCenter, expectedX: expectedX)
    }
    
    // 2) Vision-only servo control (same as AI mode)
    applyVisionFollower(from: faceCenter)
    
    // 3) Drift fail-safe: only if GPS is considered good and we have expectedX
    guard hasGoodGPS(), let gx = gpsExpectedX else {
        visionGpsDriftFrames = 0
        return
    }
    
    let fx = faceCenter.x
    let diff = abs(fx - gx)   // 0..1 normalized screen units
    
    if diff > visionGpsDriftThreshold {
        visionGpsDriftFrames += 1
        if visionGpsDriftFrames >= visionGpsDriftFrameLimit {
            // We've been disagreeing badly for too long → drop Vision lock
            print("⚠️ GPS+AI: Vision/GPS drift too high for too long → dropping LOCKED → SEARCHING")
            trackState = .searching
            consecutiveLockFrames = 0
            consecutiveLostFrames = 0
            visionGpsDriftFrames = 0
        }
    } else {
        // Back in a reasonable band → reset drift counter
        visionGpsDriftFrames = 0
    }
}
```

**Key Features:**
- Vision still has 100% servo control
- Monitors drift between Vision and GPS
- If drift >30% for 15+ frames, automatically drops lock
- Returns to `.searching` state for GPS-first reacquisition

### 6.5 Update State Reset Logic

**Location:** In `onChange(of: trackingMode)` handler, add drift frames reset

```swift
// Reset tracking state machine when switching modes
if newMode == .cameraAI || newMode == .gpsAI {
    trackState = .searching
    consecutiveLockFrames = 0
    consecutiveLostFrames = 0
    visionGpsDriftFrames = 0  // ← Add this
}

// Reset GPS metrics when leaving GPS+AI mode
if newMode != .gpsAI {
    gpsBias = 0.0
    gpsErrorRMS = 0.0
    gpsSampleCount = 0
    visionGpsDriftFrames = 0  // ← Add this
}
```

### 6.6 Behavior Summary

**Searching/Lost States:**
- **GPS-First:** GPS drives the servo by default
- **Vision Alignment:** Vision only takes control when aligned with GPS (within 8%)
- **GPS Bad:** Falls back to Vision-only if GPS is unreliable

**Locked State:**
- **Vision Control:** Vision has 100% servo control
- **Drift Monitoring:** Watches for long-term disagreement with GPS
- **Fail-Safe:** Drops lock if Vision drifts >30% from GPS for 15+ frames

### 6.7 Configuration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Vision-GPS match threshold | 8% | Max difference for Vision to take control in searching/lost |
| Vision-GPS drift threshold | 30% | Max drift before triggering fail-safe in locked state |
| Vision-GPS drift frame limit | 15 frames | Consecutive drift frames before dropping lock (~1.5s at 10Hz) |
| GPS trust threshold | 0.6 | Minimum gpsTrust score for GPS to be considered "good" |

---

**Last Updated:** 2024
**Version:** 1.3 (GPS-First Fusion Logic - Searching/Lost states use GPS as primary driver, Locked state includes drift fail-safe)

