# SurfCam Master Tracking & Zoom System Documentation

**Complete reference for GPS/AI tracking, camera zoom, and all related systems.**

---

## 📋 Table of Contents

1. [System Overview](#system-overview)
2. [System Architecture](#system-architecture)
3. [Tracking Modes](#tracking-modes)
4. [GPS Calibration System](#gps-calibration-system)
5. [Tracking State Machine](#tracking-state-machine)
6. [GPS Trust Metrics](#gps-trust-metrics)
7. [GPS+AI Fusion Algorithm](#gpsai-fusion-algorithm)
8. [Zoom System](#zoom-system)
9. [Integration: Zoom & Tracking](#integration-zoom--tracking)
10. [Core Components](#core-components)
11. [Key Algorithms](#key-algorithms)
12. [Data Flow](#data-flow)
13. [Configuration Parameters](#configuration-parameters)
14. [Implementation Details](#implementation-details)
15. [Troubleshooting](#troubleshooting)
16. [File Locations](#file-locations)

---

## System Overview

The SurfCam tracking system combines **Vision-based AI tracking** (Apple Vision Framework) with **GPS tracking** (Apple Watch) to create a robust, multi-modal tracking solution. The system includes a sophisticated zoom system with preset-based control and dynamic FOV calculations.

### Key Features

- **Three Tracking Modes**: AI-only, GPS-only, GPS+AI fusion
- **State Machine**: Intelligent state management (searching, locked, lost)
- **GPS-First Fusion**: GPS drives servo in search, Vision takes over when aligned
- **Drift Fail-Safe**: Monitors Vision/GPS disagreement and recovers automatically
- **Zoom Presets**: 4 preset levels (0.5x, 1x, 2x, 4x) with dynamic FOV
- **GPS Trust Metrics**: Real-time telemetry on GPS/Vision alignment
- **Two-Step Calibration**: Separate rig and center calibration for accuracy

---

## System Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    CameraScreen                         │
│  (Main Controller - Mode Selection & Tracking Loop)    │
│  - Tracking State Machine                              │
│  - GPS Trust Metrics                                   │
│  - Zoom Preset UI                                      │
└────────────┬────────────────────────────────────────────┘
             │
    ┌────────┴────────┐
    │                 │
    ▼                 ▼
┌─────────┐      ┌──────────────┐
│FaceTracker│    │GPS Tracking  │
│(Vision)  │    │System         │
└─────────┘      └──────────────┘
    │                 │
    │                 ├──► RigLocationManager
    │                 │   (Rig GPS Position)
    │                 │
    │                 └──► WatchGPSTracker
    │                     (Watch GPS Stream)
    │
    └──► CameraSessionManager
        └──► ZoomController
            (Zoom & FOV Management)
```

### Data Flow Overview

```
Camera Frame → Vision Detection → FaceTracker → Tracking Logic → Servo Control
     ↓
Watch GPS → WatchGPSTracker → GPS Calculations → Tracking Logic → Servo Control
     ↓
Zoom Preset → ZoomController → FOV Calculation → GPS Calculations
```

---

## Tracking Modes

### 1. **Off Mode** (`TrackingMode.off`)
- No tracking active
- Camera preview only
- Servo remains stationary

### 2. **AI Mode** (`TrackingMode.cameraAI`)
- **Auto-starts** when selected
- Uses Vision Framework to detect people in frame
- Tracks the detected person's center position
- Servo follows person horizontally (keeps them centered)
- **No GPS required**

**Algorithm:**
1. Vision detects all people in frame
2. Selects best candidate (largest box, or closest to previous position)
3. Uses `applyVisionFollower()` to calculate offset from screen center (normalized 0..1)
4. Converts offset to servo angle change
5. Applies deadband to prevent jitter
6. Clamps servo angle to safe range (15-165°)

**Key Parameters:**
- Deadband: 0.03 (3% of screen width) — tighter for snappier response
- Gain: 10.0 (converts offset to angle change)
- Max step: 4.0° per tick (prevents overshoot)
- Angle range: 15-165° (safe physical limits)
- Servo mirror: -1.0 (mirrors servo direction)
- Center bias: -0.39° (nudges effective center)

### 3. **GPS Mode** (`TrackingMode.watchGPS`) – distance/motion + filtered bearing
- Auto-starts when selected; no Vision required
- Uses Watch smoothed GPS → distance/motion → filtered bearing → distance/speed-aware servo

**Algorithm (current):**
1. WatchGPS smoothedLocation (α=0.4) arrives
2. `updateDistanceAndMotionIfPossible()`
   - distance rig→watch, speed, motion heading, instant bearing
   - `updateFilteredBearing` with distance/speed-aware alpha (0.03–0.35)
3. `tickGPSServoWithDistanceAndMotion()`
   - distance/speed-aware deadband (0.7–2°)
   - max step 1–6° based on distance & speed
   - maps filtered bearing → servo target (calibratedBearing=center→90°)
4. `api.track(angle:)` after clampAngle(15–165°)

**Key Parameters (current):**
- GPS smoothing alpha (position): 0.4
- Bearing filter alpha range: 0.03–0.35 (close/slow more smoothing; far/fast more responsive)
- Max stale age: 2s
- Max step range: 1–6° (distance/speed dependent)
- Deadband range: 0.7–2° (larger when close)
- Immediate servo tick on new GPS: yes (watchGPS + active gpsAI)

### 4. **AI+ Mode** (`TrackingMode.gpsAI`) ⭐ **Fusion Mode**
- **Requires manual start** (after calibration)
- Combines GPS and Vision for best tracking
- GPS predicts where person should be on screen
- Vision confirms and tracks the person
- Falls back to GPS-only if Vision can't see target
- **Uses state machine** for intelligent control

**State-Driven Behavior:**
- **Searching**: GPS-first fusion (GPS drives, Vision takes over when aligned)
- **Locked**: Vision has 100% control (GPS only monitors for drift)
- **Lost**: GPS-first recovery (GPS searches, Vision reacquires)

**Key Features:**
- GPS gating: Only consider Vision detections near expected GPS position
- Continuity scoring: Prefer same person across frames
- Size scoring: Prefer closer (larger) people
- Automatic fallback: GPS-only when Vision fails
- Drift fail-safe: Drops lock if Vision drifts too far from GPS

---

## GPS Calibration System

### Two-Step Calibration Process

#### Step 1: Rig Calibration (Phone)
**Purpose:** Establish where the tripod/rig is located

**Process:**
1. User stands at/near the rig
2. Taps "📍 Calibrate Rig" button on phone
3. System samples GPS for 120 seconds (continuous)
4. Filters samples:
   - Reject accuracy > 3m
   - Reject stale timestamps (>2s old)
5. Requires at least 20 good samples
6. Averages samples using accuracy-weighted mean (1/σ² weighting)
7. Stores result in `rigCalibratedCoord`

**Location:** `RigLocationManager.startRigCalibration()`

#### Step 2: Center Calibration (Watch)
**Purpose:** Establish where "perfect center" is in front of camera

**Process:**
1. User stands in front of camera where they want "center"
2. Taps "🎯 Calibrate Center" button on Watch
3. Watch samples GPS for 120 seconds
4. Filters samples:
   - Reject accuracy > 3m
   - Reject stale timestamps (>2s old)
5. Requires at least 20 good samples
6. Averages samples using accuracy-weighted mean (1/σ² weighting)
7. Sends result (lat/lon + sampleCount + avgAccuracy) to phone via WatchConnectivity
8. Phone stores in `watchCalibratedCoord` and logs distance sanity vs rig (warns if <15m)

**Location:** Watch app `WatchLocationManager.startCenterCalibration()`

### Calibrated Bearing Calculation

Once both calibrations are complete:
```swift
calibratedBearing = bearing(from: rigCalibratedCoord, to: watchCalibratedCoord)
```

This bearing represents the "center" direction the camera should point.

**Usage:**
- All GPS tracking compares current bearing to `calibratedBearing`
- Servo angle 90° = pointing at `calibratedBearing`
- Servo angle 0° = `calibratedBearing - 90°`
- Servo angle 180° = `calibratedBearing + 90°`

---

## Tracking State Machine

### Overview
The tracking state machine provides intelligent state management for GPS+AI fusion mode, ensuring Vision has full control when a strong lock is established, while using GPS fusion during search and recovery phases.

### States

#### `.searching` - Initial Search Phase
- **Purpose:** Finding and acquiring the target
- **Behavior:** Uses GPS-first fusion
  - GPS computes expected screen position
  - Vision uses GPS gating for person selection
  - **GPS drives the servo** by default
  - Vision only takes control when aligned with GPS (within 8% threshold)
  - If Vision finds person aligned with GPS, starts counting toward lock

#### `.locked` - Strong Visual Lock ⭐
- **Purpose:** Maintain precise Vision-based tracking
- **Behavior:** **Vision has 100% control**
  - GPS does NOT move the servo
  - Pure Vision-based tracking (same as AI mode)
  - GPS still updates trust metrics (telemetry only)
  - Ensures smooth, responsive tracking once lock is established
  - **Drift fail-safe**: Monitors Vision/GPS disagreement, drops lock if drift >30% for 15+ frames
- **Transition:** After 12 consecutive frames with vision target (~1.2s at 10Hz)

#### `.lost` - Target Lost
- **Purpose:** Reacquire lost target using GPS
- **Behavior:** Uses GPS-first recovery
  - GPS drives the servo to search
  - Vision detection triggers return to searching state
  - Same GPS-first logic as searching state
- **Transition:** After 8 consecutive frames without vision target (~0.8s at 10Hz)

### State Transitions

```
SEARCHING → LOCKED
  Trigger: 12 consecutive frames with vision target
  Log: "🔒 Entering LOCKED state"

LOCKED → LOST
  Trigger: 8 consecutive frames without vision target
  Log: "❗️ Lost target – entering LOST state"

LOCKED → SEARCHING (Drift Fail-Safe)
  Trigger: Vision drifts >30% from GPS for 15+ frames
  Log: "⚠️ GPS+AI: Vision/GPS drift too high for too long → dropping LOCKED → SEARCHING"

LOST → SEARCHING
  Trigger: Vision target reacquired
  Log: "🔍 Vision reacquired – back to SEARCHING"
```

### Implementation Details

**State Variables:**
- `trackState: TrackState` - Current state (.searching, .locked, .lost)
- `consecutiveLockFrames: Int` - Frames with vision target
- `consecutiveLostFrames: Int` - Frames without vision target
- `visionGpsDriftFrames: Int` - Consecutive drift frames in locked state

**Thresholds:**
- `lockFramesThreshold = 12` - Frames needed for searching → locked
- `lostFramesThreshold = 8` - Frames needed for locked → lost
- `visionGpsDriftFrameLimit = 15` - Drift frames before dropping lock

**Key Methods:**
- `updateTrackState(hasVisionTarget:)` - Updates state based on vision detection
- `gpsAiSearchingTick()` - Searching state behavior (GPS-first)
- `gpsAiLockedTick()` - Locked state behavior (Vision-only + drift monitoring)
- `gpsAiLostTick()` - Lost state behavior (GPS-first recovery)

---

## GPS Trust Metrics

### Overview
GPS trust metrics provide real-time telemetry on the alignment between GPS predictions and Vision detections. This enables the system to assess GPS reliability and dynamically adjust GPS influence based on measured quality.

### Purpose
- **Telemetry Only (Current):** Collects and logs GPS quality data
- **Future Use:** Will be used for:
  - Dynamic GPS gating (adjust gate width based on trust)
  - GPS bias correction (compensate for systematic offsets)
  - Search behavior (expand search when GPS is unreliable)

### Metrics Collected

#### `gpsBias: CGFloat`
- **Definition:** Running average of signed error (gpsX - visionX)
- **Interpretation:**
  - `> 0`: GPS consistently thinks target is more to the right than Vision
  - `< 0`: GPS consistently thinks target is more to the left
  - `≈ 0`: GPS and Vision are well-aligned
- **Update:** Exponential moving average (EMA) with alpha = 0.05

#### `gpsErrorRMS: CGFloat`
- **Definition:** Root mean square of absolute error magnitude
- **Units:** Normalized screen units (0..1, where 0.5 = half screen width)
- **Interpretation:**
  - `0.05` ≈ 5% of screen width typical deviation (good)
  - `0.20` ≈ 20% of screen width (bad, very noisy)
- **Update:** EMA of squared error, then square root

#### `gpsSampleCount: Int`
- **Definition:** Number of samples accumulated
- **Purpose:** Gates trust calculation (requires minimum 30 samples)

### GPS Trust Score

**Computed Property:** `gpsTrust: CGFloat` (0.0 - 1.0)

```swift
private var gpsTrust: CGFloat {
    // Not enough data yet → no trust
    guard gpsSampleCount >= gpsMinSamplesForTrust else { return 0.0 }
    
    // Error component: 1 when error ≈ 0, goes toward 0 as RMS error grows
    let normalizedError = gpsErrorRMS / gpsMaxScreenErrorForTrust
    let errorComponent = max(0.0, 1.0 - normalizedError)  // clamp to [0, 1]
    
    return errorComponent
}
```

**Interpretation:**
- `1.0`: Perfect alignment (GPS and Vision agree)
- `0.5`: Moderate alignment (some error, but usable)
- `0.0`: Poor alignment or insufficient samples

### Update Logic

**When Metrics Update:**
- Only in **GPS+AI mode**
- Only in **`.locked` state** (Vision is trusted)
- Requires both:
  - `faceTracker.faceCenter` (Vision detection)
  - `gpsExpectedX` (GPS prediction)

**Update Function:**
```swift
private func updateGPSQualityMetrics(faceCenter: CGPoint, expectedX: CGFloat)
```

**Update Frequency:**
- Every frame when conditions are met
- Logs every 30 samples to avoid console spam

### Console Output

When metrics are being collected, you'll see logs like:

```
📡 GPS Quality – samples=30 bias=0.042 rms=0.065 trust=0.74
📡 GPS Quality – samples=60 bias=0.038 rms=0.058 trust=0.77
```

**Reading the Logs:**
- `samples`: Number of data points collected
- `bias`: Average signed error (positive = GPS right of Vision)
- `rms`: Root mean square error magnitude
- `trust`: Computed trust score (0.0-1.0)

### Reset Behavior

GPS metrics reset when:
- Tracking mode changes away from GPS+AI
- Tracking is turned off
- Ensures telemetry is session-scoped

---

## GPS+AI Fusion Algorithm

### Overview
The fusion mode combines GPS prediction with Vision confirmation for robust tracking. The system uses a **state machine** to intelligently manage when GPS and Vision control the servo, ensuring smooth tracking once a visual lock is established while using GPS for search and recovery.

### State-Driven Algorithm Flow

```
┌─────────────────────────────────────────────────────────┐
│ GPS+AI Fusion Mode Entry                                │
│ trackWithGPSAIFusion()                                  │
└───────────────┬─────────────────────────────────────────┘
                │
                ▼
        ┌───────────────┐
        │ Check Current │
        │ Track State   │
        └───┬───────┬───┘
            │       │
    ┌───────┘       └───────┐
    │                       │
    ▼                       ▼
┌──────────┐          ┌──────────┐
│SEARCHING │          │  LOCKED  │
│  STATE   │          │  STATE   │
└────┬─────┘          └────┬─────┘
     │                    │
     │                    │ (Vision has 100% control)
     │                    │
     │                    ▼
     │            ┌─────────────────┐
     │            │ 1. Update GPS    │
     │            │    Trust Metrics │
     │            │    (telemetry)   │
     │            └────────┬─────────┘
     │                     │
     │                     ▼
     │            ┌─────────────────┐
     │            │ 2. Pure Vision   │
     │            │    Tracking      │
     │            │ applyVisionFollower│
     │            └─────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│ 1. Compute Expected X from GPS      │
│    expectedX = computeExpectedX()   │
└───────────────┬─────────────────────┘
                │
                ▼
        ┌───────────────┐
        │ expectedX ==  │
        │    nil?       │
        └───┬───────┬───┘
            │       │
         YES│       │NO (in FOV)
            │       │
            ▼       ▼
    ┌──────────┐  ┌──────────────────┐
    │ Outside  │  │ Inside FOV       │
    │ FOV      │  │                  │
    └────┬─────┘  └────┬─────────────┘
         │            │
         │            ▼
         │    ┌───────────────┐
         │    │ Vision found  │
         │    │   person?     │
         │    └───┬───────┬───┘
         │        │       │
         │     YES│       │NO
         │        │       │
         │        ▼       ▼
         │  ┌─────────┐ ┌──────────────┐
         │  │ Track   │ │ Pan toward   │
         │  │ with AI│ │ GPS expectedX │
         │  │ (GPS   │ │ (slow search) │
         │  │ gated) │ │               │
         │  └─────────┘ └──────────────┘
         │
         ▼
    ┌──────────────┐
    │ Use GPS-only │
    │ tracking to  │
    │ rotate rig   │
    │ toward target│
    └──────────────┘
```

### State-Specific Behavior

#### `.searching` State - GPS-First Acquisition
**Purpose:** Find and acquire the target using GPS as primary driver

**Behavior (GPS-First Fusion):**
1. **Check GPS Quality:**
   - If GPS is not good (`hasGoodGPS() == false`), fall back to Vision-only if available
   - If GPS is good, proceed with GPS-first logic
2. **Compute Expected X:**
   - Calculate `expectedX` from GPS (using dynamic FOV from zoom preset)
   - Set `faceTracker.expectedX = expectedX` (enables GPS gating)
3. **GPS + Vision Alignment Check:**
   - **If both GPS expectedX (in FOV) AND Vision target exist:**
     - Calculate difference: `abs(visionX - gpsX)`
     - **If difference < `visionGpsMatchThreshold` (8%):**
       - ✅ Vision and GPS agree → Vision takes over servo control
       - Track using `applyVisionFollower()` (same as AI mode)
       - Count consecutive frames toward lock
     - **If difference ≥ threshold:**
       - Vision sees someone but not aligned with GPS
       - GPS drives the servo (treat GPS as source of truth)
   - **If GPS is good but no Vision target OR GPS says outside FOV:**
     - Use GPS-only tracking to drive servo

**Key Principle:** In searching state, **GPS drives the rig**. Vision only takes control when it aligns with GPS predictions (within 8% screen width).

**Transition to `.locked`:** After 12 consecutive frames with vision target (~1.2s at 10Hz)

#### `.locked` State - Vision Has Full Control with Drift Fail-Safe ⭐
**Purpose:** Maintain precise Vision-based tracking without GPS interference, but monitor for long-term drift

**Behavior:**
1. **GPS Trust Metrics Update** (telemetry only):
   - If `expectedX` is available, update `gpsBias`, `gpsErrorRMS`, `gpsSampleCount`
   - Logs GPS quality every 30 samples
   - **Does NOT affect servo movement**
2. **Pure Vision Tracking:**
   - Uses `applyVisionFollower()` - identical to AI mode
   - GPS does NOT move the servo
   - Ensures smooth, responsive tracking
3. **Drift Fail-Safe:**
   - Monitors alignment between Vision and GPS predictions
   - If GPS is good and `expectedX` is available:
     - Calculate drift: `abs(visionX - gpsX)`
     - **If drift > `visionGpsDriftThreshold` (30%):**
       - Increment `visionGpsDriftFrames` counter
       - **If counter ≥ `visionGpsDriftFrameLimit` (15 frames = ~1.5s):**
         - Drop Vision lock → transition to `.searching`
         - Reset all counters
         - Log: "⚠️ GPS+AI: Vision/GPS drift too high for too long → dropping LOCKED → SEARCHING"
     - **If drift ≤ threshold:**
       - Reset drift counter (Vision and GPS are aligned)

**Key Point:** In locked state, Vision has 100% control of servo movement, but the system monitors for long-term disagreement with GPS. If Vision drifts too far from GPS predictions for too long (30% screen width for 1.5 seconds), the system automatically drops the lock and returns to GPS-first searching mode.

**Transition to `.lost`:** After 8 consecutive frames without vision target (~0.8s at 10Hz)
**Transition to `.searching`:** If Vision drifts >30% from GPS for 15+ frames while GPS is reliable

#### `.lost` State - GPS-First Recovery Mode
**Purpose:** Reacquire lost target using GPS-first search

**Behavior:**
- Uses same GPS-first logic as `.searching` state (`runExistingGPSAIBehavior()`)
- **GPS drives the servo** to search for target
- Vision only takes control when aligned with GPS (within 8% threshold)
- Vision detection triggers return to `.searching` state

**Key Principle:** Same as searching - GPS is primary, Vision only takes over when aligned.

**Transition to `.searching`:** When Vision reacquires target

### Vision Follower (Shared Logic)

**Function:** `applyVisionFollower(from faceCenter: CGPoint)`

**Used by:**
- AI Mode (`trackWithCameraAI()`)
- GPS+AI Locked State (`gpsAiLockedTick()`)

**Ensures coordinate consistency across all Vision tracking modes.**

**Algorithm:**
```swift
let x = faceCenter.x              // 0..1 (normalized Vision coord)
let offset = x - 0.5              // -0.5..+0.5 (center = 0)

// Apply center bias (nudges effective center)
let centerBiasNorm = centerBiasDegrees / gain
let offset = (x + centerBiasNorm) - 0.5

// Deadband: ignore tiny movements near center
if abs(offset) < 0.02 { return }  // 2% of screen width

// Convert offset to angle change
let gain: CGFloat = 10.0
var step = offset * gain * servoMirror  // degrees left/right (servoMirror = -1.0)

// Clamp step size
let maxStep: CGFloat = 4.0
step = max(-maxStep, min(maxStep, step))

// Apply to servo
let newAngle = clampAngle(currentAngle + step)
sendServoAngle(newAngle)
```

**Key Parameters:**
- **Deadband:** 0.02 (2% of screen) - prevents jitter near center
- **Gain:** 10.0 - converts normalized offset to degrees
- **Max Step:** 4.0° - limits movement per frame
- **Servo Mirror:** -1.0 - mirrors servo direction (change to 1.0 for normal)
- **Center Bias:** -0.39° - nudges effective center
- **Angle Range:** 15-165° - avoids physical limits

### GPS Gating Scoring Formula
```swift
score = 0.50 * gpsScore + 0.35 * continuityScore + 0.15 * sizeScore

where:
  gpsScore = 1.0 - (|person.x - expectedX| / 0.3)  // Clamped to [0, 1]
  continuityScore = 1.0 - (distance / 0.2)  // Clamped to [0, 1]
  sizeScore = min(1.0, person.area / 0.1)
```

**Note:** GPS gating is only active in `.searching` and `.lost` states. In `.locked` state, Vision has full control and GPS gating is not used for servo movement (only for telemetry).

---

## Zoom System

### Overview
The zoom system provides flexible camera zoom control with multiple modes. The system uses **preset-based zoom** with dynamic FOV calculations that integrate with GPS tracking.

### Current Implementation Status

**✅ Working:**
- **Zoom Presets**: Preset-based zoom system (0.5x, 1x, 2x, 4x via UI buttons)
- **Fixed Zoom Mode**: Presets map to fixed zoom factors
- **Dynamic FOV**: `ZoomController.currentHFOV` uses preset-based FOV (110°, 78°, 40°, 22°)
- **GPS Dynamic FOV**: ✅ **INTEGRATED** - GPS uses `zoomController.currentHFOV` for accurate expectedX calculations
- **Multi-Camera Support**: Uses triple/dual camera when available (enables 0.5x ultra-wide)
- **Device-Safe Zoom**: Respects `minAvailableVideoZoomFactor` and `maxAvailableVideoZoomFactor`

**❌ Not Integrated (but code exists):**
- Auto subject size mode (logic exists, not called from tracking loop)
- Search mode for GPS+AI (functions exist, not called)

### Zoom Presets

**Enum:** `ZoomPreset` (in `ZoomController.swift`)

| Preset | UI Factor | Display Name | FOV | Description |
|--------|-----------|--------------|-----|-------------|
| `ultraWide05` | 0.5x | "0.5x" | 110° | Ultra-wide anchor |
| `wide1` | 1.0x | "1x" | 78° | Main lens anchor |
| `tele2` | 2.0x | "2x" | 40° | Mid tele anchor |
| `tele4` | 4.0x | "4x" | 22° | Long tele anchor |

**Key Properties:**
- `uiZoomFactor: CGFloat` - Camera-app style factor per preset (device clamps)
- `displayName: String` - UI display name ("0.5x", "1x", "2x", "4x")
- `currentPreset: ZoomPreset` - Tracks active preset in `ZoomController`
- `applyPreset(_:)` - Updates mode, zoomFactor, and FOV based on preset

### Zoom Modes

#### 1. Fixed Zoom Mode (Preset-Based)
**Enum Value:** `ZoomMode.fixed(CGFloat)`

**Description:** Locks zoom to a specific factor via zoom presets

**Behavior:**
- User selects preset via UI buttons (0.5x, 1x, 2x, 4x)
- Preset maps to logical zoom factor (device may clamp to actual max)
- `currentPreset` tracks active preset
- FOV automatically updates based on preset
- No automatic adjustments

**Use Cases:**
- Manual control with preset-based FOV
- Consistent framing
- Specific shot requirements

#### 2. Auto Subject Size Mode
**Enum Value:** `ZoomMode.autoSubjectSize`

**Description:** Automatically adjusts zoom to keep the tracked subject at ~40% of frame height

**Behavior:**
- Monitors subject height from Vision detections
- Adjusts zoom when subject is outside tolerance (±10%)
- Gentle adjustments (0.5x error multiplier) to prevent oscillation
- Only adjusts if subject height > 5% (ignores tiny detections)

**⚠️ NOT CURRENTLY INTEGRATED:** Logic exists but `updateZoom()` is never called from tracking loop.

#### 3. Off Mode
**Enum Value:** `ZoomMode.off`

**Description:** Disables all automatic zoom changes from code

**Behavior:**
- No zoom adjustments from tracking system
- User can still manually control zoom (if UI supports it)
- Useful for manual control or testing

### FOV Calculation

**Location:** `ZoomController.currentHFOV`

**Preset-Based FOV:**
```swift
var currentHFOV: Double {
    switch currentPreset {
    case .ultraWide05: return 110   // 0.5x ultra-wide
    case .wide1:      return 78    // 1x main
    case .tele2:      return 40    // 2x mid tele
    case .tele4:      return 22    // 4x long tele
    }
}
```

**✅ INTEGRATED:** GPS calculations now use this dynamic FOV.

**GPS FOV Usage:**
- `expectedXFromGPS()` accepts `cameraHFOV: Double` as a parameter
- `computeExpectedXFromGPS()` passes `zoomController.currentHFOV`
- GPS expectedX calculations now accurately reflect current zoom preset

**Note:** These are reasonable approximations and can be tuned later. Real FOV depends on:
- Physical lens (0.5x ultra-wide, 1x wide, 2x telephoto)
- Digital zoom factor
- Device model

### Camera Device Selection

**Location:** `CameraSessionManager.makeBackCameraDevice()`

**Priority Order:**
1. **Triple Camera** (iPhone 13/14/15/17 Pro) - Enables 0.5x, 1x, 2x, 3x physical lenses
2. **Dual Wide Camera** - Fallback for dual-camera devices
3. **Wide Angle Camera** - Final fallback for single-camera devices

**Benefits:**
- Enables physical lens switching (not just digital zoom)
- Supports ultra-wide (0.5x) preset
- Better image quality at different zoom levels

### Zoom Control Implementation

**CameraSessionManager.setZoom():**
```swift
func setZoom(_ factor: CGFloat) {
    guard let device = videoDevice else { return }
    
    do {
        try device.lockForConfiguration()
        
        // Use device's real min/max zoom (allows ultra-wide 0.5x on triple-cam)
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
        
        let clamped = max(minZoom, min(factor, maxZoom))
        
        if device.isRampingVideoZoom {
            device.cancelVideoZoomRamp()
        }
        
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        
        // Keep ZoomController in sync
        DispatchQueue.main.async {
            self.zoomController?.syncZoomFactorFromDevice(clamped)
        }
    } catch {
        print("❌ Zoom error: \(error)")
    }
}
```

**Key Points:**
- Respects device min/max zoom (enables 0.5x on multi-camera devices)
- Prevents zoom ramping conflicts
- Updates ZoomController on main thread

### Video Capture & Scaling (feed-ready facts)
- Capture device: picks built-in triple → dual-wide → wide (physical lens switching for 0.5x/1x/2x/3x where available).
- Zoom range: clamps to device `minAvailableVideoZoomFactor` (often ~0.5 on multi-cam) up to `min(maxAvailableVideoZoomFactor, 10.0)`; presets request 0.5x/1x/2x/4x; `ZoomPreset.deviceZoomFactor` scales from the device's minAvailableVideoZoomFactor (ultra-wide base) so 1x/2x/4x map correctly to physical lenses.
- FOV: `currentHFOV` uses presets (110°, 78°, 40°, 22°) and is passed into `expectedXFromGPS`; Vision still uses normalized 0..1 coordinates, so servo math is unchanged by zoom.
- Resolution/FPS: defaults to 1080p @ 30fps; optional 4K toggle in UI; tracking loop runs at 20 Hz (0.05s) with immediate GPS-triggered ticks in watchGPS/gpsAI.
- Servo safety: angles clamped to 15–165°, servoMirror = -1.0, centerBias = -0.39°; Vision follower still max 4°/tick; GPS servo uses filtered bearing with distance/speed-based deadband + maxStep (up to ~6°).
- Feed takeaway: video feed scales with the active zoom preset + device lens; tracking math stays normalized, and GPS math uses the live FOV so expectedX matches what the feed shows.

---

## Integration: Zoom & Tracking

### Vision Tracking (AI Mode & GPS+AI Locked)

**Coordinate System:**
- Vision uses normalized coordinates (0..1) regardless of zoom
- `faceCenter.x` is always 0..1 (left to right)
- `faceCenter.y` is always 0..1 (bottom to top)

**Zoom Impact:**
- **Detection Accuracy**: Higher zoom = better detail = more accurate detections
- **FOV**: Higher zoom = narrower FOV = subject more likely to leave frame
- **Subject Size**: Higher zoom = larger subject in frame (affects auto-zoom)

**Key Point:** The tracking math (`applyVisionFollower`) doesn't change with zoom because it uses normalized coordinates. However, zoom affects:
- How quickly subject can leave frame
- Detection reliability
- Auto-zoom calculations

### GPS Tracking

**Coordinate System:**
- GPS uses absolute compass bearings (0..360°)
- Converts to screen X using FOV calculations

**Zoom Impact:**
- **FOV Changes**: Higher zoom = narrower FOV = smaller "in-frame" angle range
- **Expected X Accuracy**: FOV must match actual camera FOV for accurate predictions
- **Gate Width**: GPS gating uses expectedX ± threshold, which is affected by FOV accuracy

### Auto Distance Zoom (live distance-driven zoom)
- **Mode:** `ZoomMode.autoDistance` (toggle via “Auto Zoom” UI button).
- **Inputs:** `gpsDistanceMeters`, `gpsDistanceIsValid` (from CameraScreenViewModel), `gpsTrust`, `hasGoodGPS`.
- **Mapping:** 30/80/150 m → 1x/2x/4x (linear bands), capped at 4x.
- **Floor:** Floor to `max(autoDistanceZoomFloor=1.5x, preset at enable)`, never below 0.5x, capped 4x.
- **Smoothing:** α=0.15 toward target, maxΔ=0.15x per tick, 2 m distance deadband to ignore jitter.
- **Guardrails:** Requires `hasGoodGPS` + `gpsTrust ≥ 0.4`; otherwise no-op.
- **UI:** “Auto Zoom” capsule button in bottom controls; distance debug label (top row, monospaced) shows meters/feet when valid.
- **Behavior:** Runs every tracking tick; uses same flow for all modes but only acts when autoDistance is enabled and GPS is good.

**Example:**
```
At 1.0x zoom: FOV = 78° → ±39° from center = full frame
At 3.0x zoom: FOV = 30° → ±15° from center = full frame

If GPS says target is at +20° from center:
- At 1.0x: expectedX ≈ 0.76 (in frame)
- At 3.0x: expectedX ≈ 1.17 (outside frame, clamped to 1.0)
```

**✅ INTEGRATED:** GPS now uses dynamic FOV from zoom preset.

**Distance + Motion + Filtered Bearing (GPS pipeline):**
- CameraScreen keeps distance/speed/bearing state: `gpsDistanceMeters`, `gpsSpeedMps`, `gpsBearingRigToWatch` (instant), `gpsFilteredBearing` (smoothed), `gpsMotionHeading` (prev→current heading if segment >0.5m), `lastSmoothedWatchLocation`.
- `updateDistanceAndMotionIfPossible()`:
  - distance = rig→watch (smoothed GPS)
  - instant bearing = rig→watch
  - speed + motion heading from last smoothed point (dt>=0.1s; ignores <0.5m jitter)
  - updates `gpsFilteredBearing` via `updateFilteredBearing(withInstantBearing:)`.
- `updateFilteredBearing`: distance- and speed-aware smoothing (alpha 0.03–0.35): closer/slower = more smoothing, farther/faster = more responsive; slight bias toward motion heading when moving (>0.8 m/s). Output normalized to [0, 360).
- `tickGPSServoWithDistanceAndMotion()`: maps filtered bearing → servo target (calibratedBearing=center→90°), uses distance/speed-aware deadband + maxStep (up to 6°) to move smoothly, clamps servo to safe range via existing `clampAngle`.

**Watch GPS mode flow (20 Hz timer + on GPS):**
1) Guard fresh GPS (`isReceiving`).
2) `updateDistanceAndMotionIfPossible()` (distance/speed/motion + filtered bearing).
3) `tickGPSServoWithDistanceAndMotion()` drives servo toward filtered bearing with dynamic deadband/step.

**GPS+AI Fusion (searching/lost) flow:**
- Existing fusion/gating logic remains.
- When GPS drives the rig (searching/lost), it now calls the same distance/motion pipeline (`updateDistanceAndMotionIfPossible` + `tickGPSServoWithDistanceAndMotion`). Vision takeover still uses `applyVisionFollower` unchanged.

### GPS+AI Fusion

**Zoom Impact:**
- **Search Mode**: Zoom in when target expected but not found (not currently integrated)
- **Locked Mode**: Auto-zoom adjusts based on subject size (not currently integrated)
- **FOV Accuracy**: Critical for GPS expectedX calculations (✅ integrated)

**State Machine Interaction:**
- **Searching**: Can zoom in to help Vision find target (not currently integrated)
- **Locked**: Normal auto-zoom operation (not currently integrated)
- **Lost**: Can zoom in to help reacquire (not currently integrated)

---

## Core Components

### 1. **FaceTracker** (`FaceTracker.swift`)
**Purpose:** Vision-based person detection and tracking

**Key Properties:**
- `faceCenter: CGPoint?` - Normalized (0..1) center of tracked person
- `allDetections: [PersonDetection]` - All detected people this frame
- `currentTargetID: UUID?` - ID of currently tracked person
- `expectedX: CGFloat?` - GPS-predicted screen X (for gating)
- `useGPSGating: Bool` - Enable GPS-gated selection

**Key Methods:**
- `process(_ sampleBuffer: CMSampleBuffer)` - Process camera frame
- `updateOrientation()` - Update for device rotation
- `resetTracking()` - Clear state when switching modes
- `scorePerson(_:expectedX:previousCenter:)` - Score person for GPS gating
- `pickBestTarget(candidates:expectedX:previousCenter:)` - Select best person

**Vision Pipeline:**
1. Receive `CMSampleBuffer` from camera
2. Extract `CVPixelBuffer`
3. Create `VNDetectHumanRectanglesRequest`
4. Process with `VNImageRequestHandler`
5. Filter by confidence (≥0.5)
6. Score and select best person
7. Apply smoothing (alphaX = 0.5, alphaY = 0.3)
8. Publish `faceCenter` on main thread

**GPS Gating Logic:**
- If `useGPSGating = true` and `expectedX` is set:
  - Score each person: `0.50 * gpsScore + 0.35 * continuityScore + 0.15 * sizeScore`
  - GPS score: 1.0 if within 30% of expected X, decays to 0
  - Continuity score: 1.0 if near previous position, decays with distance
  - Size score: Based on bounding box area (larger = closer)

### 2. **RigLocationManager** (`RigLocationManager.swift`)
**Purpose:** Manage rig/tripod GPS location and calibration

**Key Properties:**
- `rigLocation: CLLocation?` - Live GPS location
- `rigCalibratedCoord: CLLocationCoordinate2D?` - Averaged calibration position
- `isCalibrating: Bool` - Calibration in progress
- `calibrationProgress: Double` - 0..1 progress indicator

**Calibration Process:**
1. User taps "Calibrate Rig" button
2. Samples GPS for 120 seconds (continuous)
3. Filters samples:
   - Reject accuracy > 3m
   - Reject stale timestamps (>2s old)
4. Requires ≥20 good samples
5. Averages samples using accuracy-weighted mean (1/σ² weighting)
6. Stores result in `rigCalibratedCoord`

**Key Methods:**
- `startRigCalibration()` - Begin 30-second window with accuracy/staleness filters
- `finishRigCalibration()` - Validate min samples, weighted-average, store result
- `clearRigCalibration()` - Clear stored calibration

### 3. **WatchGPSTracker** (`WatchGPSTracker.swift`)
**Purpose:** Receive and process Watch GPS location stream

**Key Properties:**
- `lastWatchLocation: CLLocation?` - Raw GPS location
- `smoothedLocation: CLLocation?` - Exponential smoothed location
- `isReceiving: Bool` - True if receiving recent updates (<2s old)
- `updateRate: Double` - Updates per second
- `latency: TimeInterval` - Time since last update
- `watchCalibratedCoord: CLLocationCoordinate2D?` - Watch center calibration

**Smoothing:**
- Exponential smoothing: `new = prev * (1-α) + current * α`
- Alpha = 0.4 (40% new data, 60% previous)
- Reduces GPS jitter for smooth servo movement

**Staleness Detection:**
- Updates considered stale after 2 seconds
- `isReceiving` becomes false if no update in 2s

**Live GPS Filtering (from Watch):**
- Accepts only points with horizontalAccuracy ≤ 3.2m and age ≤ 2s
- Drops anything worse/older before smoothing
- Smoothing alpha = 0.4 (40% new / 60% previous) for responsiveness
- Prevents tracking with outdated GPS data

**WatchConnectivity:**
- Receives messages from Watch app via `WCSession`
- Handles two message types:
  1. Location updates: `["locations": [[lat, lon, ts, acc]]]`
  2. Center calibration: `["centerCalibration": {lat, lon, samples}]`

**Key Methods:**
- `resetSmoothing()` - Clear smoothing state (new session)
- `clearWatchCalibration()` - Clear center calibration

### 4. **GPSHelpers** (`GPSHelpers.swift`)
**Purpose:** GPS calculation utilities

**Functions:**

#### `bearing(from:to:) -> Double`
Calculate compass bearing between two coordinates.
- Returns: 0-360° (0=North, 90=East, 180=South, 270=West)
- Uses haversine formula with atan2

#### `averagedCoordinate(from:) -> CLLocationCoordinate2D?`
Average multiple GPS samples with accuracy weighting.
- Weight = 1/(accuracy²) - better accuracy = higher weight
- Minimum accuracy clamped to 3m (prevents single point dominance)
- Returns accuracy-weighted mean coordinate

#### `expectedXFromGPS(rigCoord:watchCoord:calibratedBearing:currentCameraHeading:cameraHFOV:) -> CGFloat?`
Calculate expected screen X position (0..1) from GPS data.
- Computes bearing from rig → watch
- Compares to current camera heading
- Maps angle difference to screen position
- Returns `nil` if target outside FOV
- **✅ Uses dynamic FOV parameter** (from `zoomController.currentHFOV`)

**Parameters:**
- `cameraHFOV: Double` - Horizontal field of view in degrees (passed from `zoomController.currentHFOV`)
  - Preset-based: ultraWide=100°, wide=78°, mid=60°, tele2=45°, tele3=30°
- Maps `[-HFOV/2, +HFOV/2]` → `[0, 1]`

#### `servoAngleToHeading(servoAngle:calibratedBearing:) -> Double`
Convert servo angle (0-180) to compass heading.
- Assumes servo 90° = calibrated center bearing
- Servo 0° = center - 90°
- Servo 180° = center + 90°

### 5. **ZoomController** (`ZoomController.swift`)
**Purpose:** Manage camera zoom with multiple modes

**Key Properties:**
- `zoomFactor: CGFloat` - Current zoom (0.5 - 4.0)
- `mode: ZoomMode` - Current zoom mode
- `isSearching: Bool` - True when searching for target
- `currentPreset: ZoomPreset` - Active zoom preset
- `currentHFOV: Double` - Preset-based horizontal FOV

**Zoom Modes:**
- `fixed(CGFloat)` - Locked zoom level (e.g., 1.0x, 2.0x)
- `autoSubjectSize` - Automatically adjust to keep subject at 40% frame height
- `off` - No automatic zoom changes

**Key Methods:**
- `applyPreset(_ preset: ZoomPreset)` - Apply zoom preset
- `setZoomLevel(_ level: CGFloat)` - Set specific zoom
- `updateZoom(for targetHeight: CGFloat?)` - Mode-based update (not currently called)
- `targetExpectedButNotFound()` - Search mode trigger (not currently called)
- `targetFound()` - Reset search state (not currently called)
- `targetOutsideFOV()` - Reset search state (not currently called)

**FOV Calculation:**
- `currentHFOV: Double` - Preset-based horizontal FOV
  - `ultraWide` (0.5x): 100° (very wide)
  - `wide` (1.0x): 78° (main camera)
  - `mid` (1.5x): 60° (mid zoom)
  - `tele2` (2.0x): 45° (tele)
  - `tele3` (3.0x): 30° (tight tele)
- ✅ **INTEGRATED**: GPS uses `zoomController.currentHFOV` for dynamic FOV calculations

### 6. **CameraSessionManager** (`CameraSessionManager.swift`)
**Purpose:** Centralized camera session management

**Responsibilities:**
- Camera input/output configuration
- Preview layer management
- Video recording
- Orientation handling
- Autofocus/exposure configuration
- Multi-camera device selection
- Zoom control

**Outputs:**
1. **AVCaptureVideoDataOutput** - For Vision processing
2. **AVCaptureMovieFileOutput** - For video recording
3. **AVCaptureVideoPreviewLayer** - For on-screen preview

**Key Methods:**
- `setupSession()` - Configure camera session
- `makeBackCameraDevice()` - Select best available back camera (triple/dual/wide)
- `setVideoFrameDelegate(_:)` - Set Vision delegate
- `startRecording()` / `stopRecording()` - Video recording
- `updateOrientation()` - Handle device rotation
- `setZoom(_:)` - Control zoom level (device-safe clamping)
- `setResolution(_:)` - Switch between 1080p and 4K

**Critical Fix:**
- Delegate must be set **after** session setup, or stored and applied during setup
- Otherwise Vision frames won't be delivered

**Multi-Camera Support:**
- Prefers triple camera (iPhone 13/14/15/17 Pro)
- Falls back to dual-wide or single wide-angle
- Enables physical lens switching (0.5x, 1x, 2x, 3x)

---

## Key Algorithms

### 1. Servo Angle Calculation (GPS Mode) – Legacy helper (pre distance/motion pipeline)

```swift
func servoAngleForCurrentGPS() -> Double? {
    // Get coordinates
    let rigCoord = rigCalibratedCoord ?? rigLocation
    let watchCoord = watchLocation
    guard let forward = calibratedBearing else { return nil }
    
    // Calculate current bearing
    let currentBearing = bearing(from: rigCoord, to: watchCoord)
    
    // Angle difference from center
    var delta = currentBearing - forward
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    
    // Clamp to ±90° (servo range)
    let clamped = max(-90, min(90, delta))
    
    // Normalize to 0..1
    let normalized = (clamped + 90) / 180
    
    // Convert to servo angle (0-180)
    return normalized * 180
}
```

### 2. AI Tracking Offset Calculation

**Note:** This is implemented in the shared `applyVisionFollower()` function used by both AI mode and GPS+AI locked state.

```swift
// Vision gives us normalized center (0..1, origin at bottom-left)
// Use non-mirrored X for consistent coordinate system
let x = faceCenter.x                     // 0..1 (already normalized Vision coord)
let offset = x - 0.5                     // -0.5..+0.5

// Apply center bias (nudges effective center)
let centerBiasNorm = centerBiasDegrees / gain
let offset = (x + centerBiasNorm) - 0.5

// Apply deadband
let deadband: CGFloat = 0.02            // 2% of screen
if abs(offset) < deadband { return }     // Don't move if close to center

// Convert to angle change
let gain: CGFloat = 10.0                 // Converts offset to angle change
var step = offset * gain * servoMirror  // degrees left/right (servoMirror = -1.0)

// Clamp step size
let maxStep: CGFloat = 4.0
if step > maxStep { step = maxStep }
if step < -maxStep { step = -maxStep }

// Apply to servo with safe angle clamping (15-165°)
let currentAngle = CGFloat(api.currentAngle)
let newAngle = clampAngle(currentAngle + step)  // Clamps to 15-165° range
sendServoAngle(Int(newAngle))
```

**Key Points:**
- Uses non-mirrored X coordinate (`faceCenter.x`) for consistency
- Offset range is `-0.5..+0.5` (not `-1..+1`)
- All servo angles clamped to **15-165°** range (not 0-180°) for safety
- Shared function ensures AI mode and locked state behave identically
- Center bias allows fine-tuning of effective center position

### 3. Exponential Smoothing (GPS)

```swift
// For each coordinate component
let smoothedLat = prevLat * (1 - α) + newLat * α
let smoothedLon = prevLon * (1 - α) + newLon * α

where α = 0.4 (40% new, 60% previous)
```

### 4. Position Smoothing (Vision)

```swift
// Low-pass filter for Vision center
let alphaX: CGFloat = 0.5   // more responsive horizontally
let alphaY: CGFloat = 0.3   // keep vertical smoothing
let newCenter = CGPoint(
    x: prev.x * (1 - alphaX) + raw.x * alphaX,
    y: prev.y * (1 - alphaY) + raw.y * alphaY
)
```

---

## Data Flow

### AI Mode Flow
```
Camera Frame
    ↓
AVCaptureVideoDataOutput
    ↓
FaceTracker.process()
    ↓
VNImageRequestHandler
    ↓
VNDetectHumanRectanglesRequest
    ↓
Person Detection Results
    ↓
Score & Select Best Person
    ↓
Smooth Position (alphaX=0.5, alphaY=0.3)
    ↓
faceCenter (Published)
    ↓
CameraScreen.trackWithCameraAI()
    ↓
applyVisionFollower()
    ↓
Calculate Servo Offset
    ↓
PanRigAPI.track(angle:)
    ↓
ESP32 Servo Control
```

### GPS Mode Flow
```
Watch GPS Location
    ↓
WatchConnectivity Message
    ↓
WatchGPSTracker.session(_:didReceiveMessage:)
    ↓
Exponential Smoothing (α=0.4) → smoothedLocation
    ↓
CameraScreen.updateDistanceAndMotionIfPossible()
    ↓
updateFilteredBearing(withInstantBearing:)
    ↓
CameraScreen.tickGPSServoWithDistanceAndMotion()
    ↓
PanRigAPI.track(angle:)
    ↓
Calculate Angle from Calibrated Bearing
    ↓
PanRigAPI.track(angle:)
    ↓
ESP32 Servo Control
```

### GPS+AI Fusion Flow
```
┌─────────────┐     ┌──────────────┐
│ Watch GPS   │     │ Camera Frame │
└──────┬──────┘     └──────┬───────┘
       │                   │
       ▼                   ▼
┌──────────────┐    ┌──────────────┐
│ Compute      │    │ Vision       │
│ Expected X   │    │ Detection    │
│ (Dynamic FOV)│    │              │
└──────┬───────┘    └──────┬───────┘
       │                   │
       └─────────┬─────────┘
                 │
                 ▼
         ┌───────────────┐
         │ Check State   │
         │ (searching/   │
         │  locked/lost) │
         └───────┬───────┘
                 │
        ┌────────┴────────┐
        │                 │
        ▼                 ▼
   ┌─────────┐      ┌──────────┐
   │SEARCHING│      │  LOCKED  │
   │(GPS-first)│    │(Vision-only)│
   └────┬────┘      └────┬─────┘
        │                │
        ▼                ▼
   ┌─────────┐      ┌──────────────┐
   │ GPS     │      │ Vision       │
   │ Gating  │      │ Tracking     │
   │ +       │      │ + GPS        │
   │ Scoring │      │ Telemetry    │
   └────┬────┘      └────┬─────────┘
        │                │
        └────────┬───────┘
                 │
                 ▼
         ┌───────────────┐
         │ Select Best   │
         │ Person        │
         └───────┬───────┘
                 │
                 ▼
         ┌───────────────┐
         │ Track with AI │
         │ or GPS-only   │
         └───────┬───────┘
                 │
                 ▼
         ┌───────────────┐
         │ Servo Control │
         └───────────────┘
```

### Zoom Integration Flow
```
User Taps Preset Button
    ↓
zoomController.applyPreset(.tele2)
    ↓
Update currentPreset, mode, zoomFactor
    ↓
CameraSessionManager.setZoom(2.0)
    ↓
Device-Safe Clamping (min/max zoom)
    ↓
AVCaptureDevice.videoZoomFactor
    ↓
Physical Lens Switch (if available)
    ↓
FOV Updates (currentHFOV = 45°)
    ↓
GPS Calculations Use New FOV
    ↓
expectedXFromGPS() with cameraHFOV=45°
```

---

## Configuration Parameters

### Tracking Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Tracking tick interval | 0.05s (20 Hz) | How often tracking loop runs |
| AI deadband | 2% | Don't move if within 2% of center |
| AI gain | 10.0 | Converts offset to angle change |
| AI max step | 4° | Maximum angle change per tick |
| Servo mirror | -1.0 | Servo direction multiplier (1.0 = normal, -1.0 = mirrored) |
| Center bias | -0.39° | Nudges effective center position |
| Vision smoothing alphaX | 0.5 | Horizontal low-pass filter strength |
| Vision smoothing alphaY | 0.3 | Vertical low-pass filter strength |
| Vision min confidence | 0.5 | Minimum detection confidence |

### GPS Parameters

| Parameter | Value | Description |
|-----------|-------------|-----------------------------------------------------------|
| GPS position smoothing alpha | 0.4 | For raw smoothedLocation from watch |
| Bearing filter alpha range | 0.03–0.35 | Smaller when close/slow, larger when far/fast |
| Max stale age | 2s | GPS considered stale after 2s |
| Max step range | 1–6° | Grows with distance and surfer speed (filtered bearing path) |
| Deadband range | 0.7–2° | Larger when close to rig, smaller when far |

### Calibration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Calibration duration | 120s | How long to sample GPS |
| Sample interval | 0.3s | GPS sample frequency |
| Max accuracy | 3.2m | Reject samples with worse accuracy |
| Max age | 2s | Reject samples older than 2s |
| Min accuracy clamp | 3m | Prevent single point dominance |
| Min good samples | 10 | Minimum valid points for a calibration |

### GPS+AI Fusion Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| GPS score weight | 50% | How much GPS proximity matters (for GPS gating) |
| Continuity weight | 35% | How much position continuity matters (for GPS gating) |
| Size weight | 15% | How much size (distance) matters (for GPS gating) |
| GPS gate threshold | 30% | Max distance from expected X (for GPS gating) |
| Continuity threshold | 20% | Max distance for continuity bonus (for GPS gating) |
| Camera HFOV | Dynamic | Horizontal field of view (preset-based: ultraWide05=110°, wide1=78°, tele2=40°, tele4=22°) |
| Vision-GPS match threshold | 8% | Max difference for Vision to take control in searching/lost states |
| Vision-GPS drift threshold | 30% | Max drift before triggering fail-safe in locked state |
| Vision-GPS drift frame limit | 15 frames | Consecutive drift frames before dropping lock (~1.5s at 10Hz) |
| GPS trust threshold | 0.6 | Minimum gpsTrust score for GPS to be considered "good" |
| Search pan gain | 2.0 | Gain for panning toward expectedX when searching |
| Search pan max step | 2.0° | Maximum step size when searching |
| Search pan deadband | 5% | Deadband for search panning |

### Tracking State Machine Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Lock frames threshold | 12 frames | Frames needed for searching → locked (~1.2s at 10Hz) |
| Lost frames threshold | 8 frames | Frames needed for locked → lost (~0.8s at 10Hz) |
| Min servo angle | 15° | Minimum safe servo angle (avoids physical limits) |
| Max servo angle | 165° | Maximum safe servo angle (avoids physical limits) |

### GPS Trust Metrics Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| GPS EMA alpha | 0.05 | Exponential moving average smoothing factor |
| Max screen error for trust | 0.25 | Maximum error treated as "very bad" (25% screen width) |
| Min samples for trust | 30 | Minimum samples before trust score > 0 |
| Log frequency | Every 30 samples | Console log frequency to avoid spam |

### Zoom Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Min zoom | 0.5x | Minimum zoom level (enables ultra-wide on multi-camera devices) |
| Max zoom | 6.0x (controller), device clamp ≤10x | ZoomController max; CameraSession clamps to device maxAvailableVideoZoomFactor |
| Default zoom | 1.0x | Default/reset zoom level |
| Zoom step | 0.1x | Incremental zoom change for gentle adjustments |
| Auto-distance zoom floor | 1.5x (≥ preset when enabled) | Floor while in autoDistance to avoid super-wide |
| Auto-distance mapping | 30/80/150 m → 1x/2x/4x | Linear bands; capped at 4x |
| Auto-distance smoothing | α=0.15, maxΔ=0.15x/tick | Exponential toward target with per-tick velocity cap |
| Auto-distance jitter deadband | 2 m | Ignore tiny distance changes |
| Target subject height | 40% | Auto-zoom target height |
| Height tolerance | ±10% | Auto-zoom tolerance |
| Search threshold | 10 frames | Frames before search mode |

### FOV Preset Parameters

| Preset | Logical Factor | FOV | Description |
|--------|---------------|-----|-------------|
| ultraWide05 | 0.5x | 110° | Ultra-wide anchor |
| wide1 | 1.0x | 78° | Main lens anchor |
| tele2 | 2.0x | 40° | Mid tele anchor |
| tele4 | 4.0x | 22° | Long tele anchor |

---

## Implementation Details

### Tracking Frequency

**Current:** 20 Hz (0.05s interval)

**Location:** `CameraScreen.restartTrackingTimer()`

```swift
trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    tickTracking()
}
```

**Benefits:**
- Faster reaction time (max delay ~50ms vs ~100ms)
- Smoother tracking
- Better responsiveness

### Coordinate System Consistency

**Critical:** Both AI mode and GPS+AI locked state use the same `applyVisionFollower()` function to ensure:
- Identical coordinate system (non-mirrored X: `x - 0.5`)
- Same deadband (2%), gain (10.0), max step (4.0°), and servo mirror (-1.0)
- No sudden flips or inconsistencies when transitioning states

### Angle Clamping

**Range:** 15-165° (not 0-180°)

**Reason:** Avoids physical limits and wiring collisions

**Location:** `CameraScreen.clampAngle()`

```swift
private func clampAngle(_ angle: CGFloat) -> CGFloat {
    let minAngle: CGFloat = 15.0
    let maxAngle: CGFloat = 165.0
    return max(minAngle, min(maxAngle, angle))
}
```

### Multi-Camera Device Selection

**Priority:**
1. Triple camera (iPhone 13/14/15/17 Pro)
2. Dual-wide camera
3. Single wide-angle camera

**Benefits:**
- Enables physical lens switching (0.5x, 1x, 2x, 3x)
- Better image quality
- Supports ultra-wide preset

**Location:** `CameraSessionManager.makeBackCameraDevice()`

### Device-Safe Zoom Clamping

**Implementation:**
```swift
let minZoom = device.minAvailableVideoZoomFactor  // e.g., 0.5 on triple-cam
let maxZoom = min(device.maxAvailableVideoZoomFactor, 6.0)
let clamped = max(minZoom, min(factor, maxZoom))
```

**Benefits:**
- Respects device capabilities
- Enables ultra-wide (0.5x) on multi-camera devices
- Prevents invalid zoom values

---

## Troubleshooting

### Vision Not Working
1. Check console for `🟢 Vision processing frame X` messages
2. Verify `setVideoFrameDelegate()` is called **after** `setupSession()`
3. Check `videoDataOutput` is not nil when delegate is set
4. Verify camera permissions in Info.plist

### GPS Not Working
1. Check `WatchGPSTracker.isReceiving` is true
2. Verify Watch app is sending location updates
3. Check `latency` - should be < 2s
4. Verify WatchConnectivity session is activated

### GPS+AI Not Tracking
1. Verify both calibrations are complete (`calibratedBearing != nil`)
2. Check `isTrackingActive` is true (GPS+AI requires manual start)
3. Verify `expectedX` is being computed (check `gpsExpectedX` in UI)
4. Check Vision is detecting people (`faceTracker.faceCenter != nil`)
5. Verify state machine is working (check console logs for state transitions)

### Servo Not Moving
1. Verify network connection to ESP32
2. Check `PanRigAPI.track(angle:)` is being called
3. Verify angle is within 15-165° range (safe clamping range)
4. Check deadband isn't preventing movement
5. Verify `servoMirror` is set correctly (-1.0 or 1.0)

### Zoom Not Working
1. Check device availability (`zoomController.videoDevice` or `cameraManager`)
2. Verify zoom value is within device min/max range
3. Check console for zoom error messages
4. Verify preset buttons are calling `zoomController.applyPreset()`
5. Check multi-camera device selection (should prefer triple camera)

### GPS ExpectedX Inaccurate
1. Verify `zoomController.currentHFOV` matches actual camera FOV
2. Check FOV preset values are correct for your device
3. Verify `expectedXFromGPS()` is receiving correct `cameraHFOV` parameter
4. Check calibration is accurate (both rig and center)

### State Machine Not Transitioning
1. Check console logs for state transition messages
2. Verify `updateTrackState()` is being called
3. Check frame thresholds (`lockFramesThreshold`, `lostFramesThreshold`)
4. Verify Vision detection is working (`hasVisionTarget`)

### Drift Fail-Safe Triggering Too Often
1. Check `visionGpsDriftThreshold` (30% may be too strict)
2. Verify GPS trust metrics (`gpsTrust` should be > 0.6)
3. Check `visionGpsDriftFrameLimit` (15 frames may be too low)
4. Verify calibration accuracy

---

## Watch App Build Guide (Better Watch Experience)

### Goals
- Reliable, low-latency GPS streaming to phone.
- Clear user feedback for calibration and live tracking.
- Robust connectivity handling (reachability, retries).
- Battery-conscious sampling while keeping accuracy targets (≤3m, ≤2s age).

### Permissions & Keep-Alive
- Request location on watch; start `HKWorkoutSession` to keep GPS frequent.
- Ensure WCSession is activated on launch; handle not-reachable states gracefully.

### UI / UX Checklist
- Home screen: status chips for accuracy (m), age (s), send rate (Hz), reachable/not.
- Buttons:
  - “Start GPS” / “Stop GPS”
  - “Calibrate Center” (30s flow, shows progress and count of good samples)
  - Optional “Send Logs” for field testing
- Indicators during calibration:
  - Progress bar over 30s
  - Good sample count, current accuracy
  - Error/toast if accuracy >2m or too few samples
- Live indicators:
  - Accuracy (m) and age (s)
  - Send rate (target ~5 Hz; rate-limited by minSendInterval=0.2s)
  - Reachability (WCSession)

### Data & Filtering (watch)
- Filters before sending:
  - horizontalAccuracy ≤ 3.2m
  - age ≤ 2s
  - rate limit: ~5 Hz (minSendInterval = 0.2s)
- Smoothing on watch: α = 0.4 (40% new / 60% previous)
- Stale after 2s → isReceiving = false on phone side.

### Message Schemas (to phone)
- Live locations: `["locations": [[lat, lon, ts, acc]]]`
- Center calibration: `["centerCalibration": { "lat": ..., "lon": ..., "samples": ..., "avgAccuracy": ... }]`

### Error Handling & Resilience
- If WCSession not reachable: surface a “Not reachable” badge; optionally queue last N points and drop the rest (battery-friendly).
- If accuracy is poor: show “Low accuracy” and keep sampling; don’t send >3m points.
- If user stops workout or revokes permissions: show a clear prompt to re-enable.

### Logging & Debugging
- Lightweight console logs for:
  - Send rate, accuracy, and age
  - Reachability changes
  - Calibration results (lat/lon, samples, avg accuracy)
- Optional: “Send Logs” button to transfer a brief summary to the phone for field tests.

### Build Targets (what “better” means)
- Accuracy: keep sent points ≤3m, ≤2s age.
- Latency: effective end-to-end under ~300–500 ms when reachable.
- UX: user always sees current accuracy/age/reachability; clear success/fail for calibration.
- Battery: stay within ~5 Hz send cap; use workout session to keep GPS responsive without excessive wakeups.

### Integration Points (phone side expectations)
- Phone enforces same filters; ignores bad/old points.
- Phone updates distance/motion/filtered bearing and servo each tick; autoDistance zoom uses `gpsDistanceIsValid` + `gpsTrust`.
- Center calibration payload updates `watchCalibratedCoord`; phone warns if rig distance <15m.

---

## File Locations

| Component | File Path |
|-----------|-----------|
| Main tracking controller | `SurfCam/CameraScreen.swift` |
| Vision tracker | `SurfCam/FaceTracker.swift` |
| GPS helpers | `SurfCam/GPSHelpers.swift` |
| Rig location manager | `SurfCam/RigLocationManager.swift` |
| Watch GPS tracker | `SurfCam/WatchGPSTracker.swift` |
| Zoom controller | `SurfCam/ZoomController.swift` |
| Camera manager | `SurfCam/CameraSessionManager.swift` |
| Camera view | `SurfCam/CameraView.swift` |
| PanRig API | `SurfCam/SurfCamApp.swift` |
| Watch location manager | `SurfCamWatch/WatchLocationManager.swift` |
| Watch GPS helpers | `SurfCamWatch/GPSHelpers.swift` |
| Watch calibration config | `SurfCamWatch/CalibrationConfig.swift` |
| Watch UI entry | `SurfCamWatch/ContentView.swift` |
| Watch app entry | `SurfCamWatch/SurfCamWatchApp.swift` |

---

## Apple Watch App (Architecture & Phone Communication)

### Purpose
- Keep GPS streaming reliably from Watch to iPhone, including calibration, background keep-alive, and resilient messaging.

### Capabilities & Permissions (Watch target)
- Signing & Capabilities: add **HealthKit**.
- Info.plist (Watch Extension): `NSLocationWhenInUseUsageDescription` (e.g., “We use your location to track you while filming.”).

### Watch Data Flow
```
CLLocationManager (watch)
    ↓ filtered (acc≤3m, age≤2s, ~5 Hz)
WCSession.sendMessage
    ↓
WatchGPSTracker (phone)
    ↓ filtered + smoothing (α=0.4, stale after 2s)
CameraScreen distance/motion + filtered bearing
    ↓
Servo control + autoDistance zoom (phone)
```

### Watch → Phone Message Schemas
- Live GPS: `["locations": [[lat, lon, ts, acc]]]`
- Center calibration: `["centerCalibration": { "lat": Double, "lon": Double, "samples": Int, "avgAccuracy": Double }]`

### Watch-Side Filtering & Rate Limits
- Accept only points with `horizontalAccuracy <= 3.2m` and `age <= 2s`.
- Rate limit: ~5 Hz (`minSendInterval = 0.2s`).
- Staleness handled on phone (no update >2s → `isReceiving = false`).

### Background / Keep-Alive (Watch)
- Uses `HKWorkoutSession` + `HKLiveWorkoutBuilder` to keep GPS active with screen off.
- Current config: activityType `.walking`, locationType `.outdoor` (could use `.otherOutdoor` too).
- Start: create session/builder, set delegates, startActivity + beginCollection; when collection starts, mark `isWorkoutActive = true` and `startUpdatingLocation()`.
- Stop/error: end collection/session, set `isWorkoutActive = false`, stopUpdatingLocation().

### Calibration on Watch
- Center calibration: 30s, ≤3m accuracy, ≥20 samples, age ≤2s, 1/σ² weighted average.
- Sends lat/lon + sampleCount + avgAccuracy to phone; phone warns if rig distance <15m.
- UI should show progress, good sample count, reachability, and result (Sent/Failed/Not reachable).

### Live Streaming Lifecycle (Watch UI expectations)
- Start button: calls `startBackgroundTracking()` (workout + GPS).
- Stop button: calls `stopBackgroundTracking()`.
- Status chips (recommended): accuracy (m), age (s), rate (Hz), reachability, workout ON/OFF.

### Phone-Side Handling (for completeness)
- File: `SurfCam/WatchGPSTracker.swift`
- Filtering: acc≤3m, age≤2s; smoothing α=0.4; staleness after 2s; `isReceiving` flag; `onLocationUpdate` callback into tracking loop.
- Calibration payload: updates `watchCalibratedCoord`; distance sanity against rig wired in `CameraScreen`.

### Watch-Side Files
- `SurfCamWatch/WatchLocationManager.swift` — WCSession, location filtering, calibration send, workout keep-alive.
- `SurfCamWatch/CalibrationConfig.swift` — thresholds (30s, 2m, 2s, min samples 20).
- `SurfCamWatch/GPSHelpers.swift` — helpers on watch.
- `SurfCamWatch/ContentView.swift` — watch UI; wire buttons to start/stop background tracking and start calibration.
- `SurfCamWatch/SurfCamWatchApp.swift` — watch app entry.

### Phone-Side Files (watch comms)
- `SurfCam/WatchGPSTracker.swift` — receives messages, filters/smooths, staleness, calibration handling.
- `SurfCam/CameraScreen.swift` — consumes smoothed GPS, distance/motion, filtered bearing; drives servo/autoDistance zoom.

---

## Version History

**Version 1.0** - Master Documentation
- Combined all tracking and zoom documentation
- Complete system reference
- All algorithms and parameters documented
- Integration details included

---

**Last Updated:** 2025
**Version:** 1.0 (Master Documentation - Complete System Reference)

