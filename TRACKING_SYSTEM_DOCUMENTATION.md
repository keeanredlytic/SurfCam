# SurfCam Tracking & AI System Documentation

## 📋 Table of Contents
1. [System Architecture](#system-architecture)
2. [Tracking Modes](#tracking-modes)
3. [Core Components](#core-components)
4. [GPS Calibration System](#gps-calibration-system)
5. [GPS+AI Fusion Algorithm](#gpsai-fusion-algorithm)
6. [Tracking State Machine](#tracking-state-machine)
7. [GPS Trust Metrics](#gps-trust-metrics)
8. [Key Algorithms](#key-algorithms)
9. [Data Flow](#data-flow)
10. [Configuration Parameters](#configuration-parameters)

---

## System Architecture

### Overview
The SurfCam tracking system combines **Vision-based AI tracking** (Apple Vision Framework) with **GPS tracking** (Apple Watch) to create a robust, multi-modal tracking solution. The system can operate in three modes:

- **AI Mode**: Pure Vision-based person detection and tracking
- **GPS Mode**: Pure GPS-based tracking using Watch location
- **AI+ Mode**: GPS+AI fusion - GPS guides where to look, Vision tracks the person

### Component Diagram
```
┌─────────────────────────────────────────────────────────┐
│                    CameraScreen                         │
│  (Main Controller - Mode Selection & Tracking Loop)    │
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
        (Camera Pipeline)
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
- Deadband: 10% of screen width
- Gain: 8.0 (converts offset to angle change)
- Max step: 4.0° per tick (prevents overshoot)
- Angle range: 15-165° (safe physical limits)

### 3. **GPS Mode** (`TrackingMode.watchGPS`)
- **Auto-starts** when selected
- Uses Watch GPS location to calculate target bearing
- Servo rotates to point at Watch location
- **No Vision required**

**Algorithm:**
1. Get current Watch GPS location (smoothed)
2. Calculate bearing from Rig → Watch
3. Compare to calibrated center bearing
4. Convert angle difference to servo position
5. Smooth servo movement (adaptive step size)

**Key Parameters:**
- Smoothing alpha: 0.4 (exponential smoothing)
- Max stale age: 2 seconds
- Adaptive step size: 3-8° based on distance

### 4. **AI+ Mode** (`TrackingMode.gpsAI`) ⭐ **Fusion Mode**
- **Requires manual start** (after calibration)
- Combines GPS and Vision for best tracking
- GPS predicts where person should be on screen
- Vision confirms and tracks the person
- Falls back to GPS-only if Vision can't see target

**Algorithm:**
1. Compute expected screen X from GPS
2. If GPS says target is in FOV:
   - Use GPS-gated person selection (Vision)
   - If Vision finds person → track with AI
   - If Vision can't find → pan toward GPS expected X
3. If GPS says target is outside FOV:
   - Use pure GPS tracking to rotate rig toward target

**Key Features:**
- GPS gating: Only consider Vision detections near expected GPS position
- Continuity scoring: Prefer same person across frames
- Size scoring: Prefer closer (larger) people
- Automatic fallback: GPS-only when Vision fails

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
7. Apply smoothing (alpha = 0.3)
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
2. Samples GPS for 7 seconds (every 0.3s)
3. Filters samples:
   - Reject accuracy > 20m
   - Reject stale timestamps (>3s old)
4. Averages samples using accuracy-weighted mean (1/σ² weighting)
5. Stores result in `rigCalibratedCoord`

**Key Methods:**
- `startRigCalibration()` - Begin 7-second sampling window
- `finishRigCalibration()` - Average samples and store result
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

#### `expectedXFromGPS(rigCoord:watchCoord:calibratedBearing:currentCameraHeading:) -> CGFloat?`
Calculate expected screen X position (0..1) from GPS data.
- Computes bearing from rig → watch
- Compares to current camera heading
- Maps angle difference to screen position
- Returns `nil` if target outside FOV

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

**Zoom Modes:**
- `fixed(CGFloat)` - Locked zoom level (e.g., 1.0x, 2.0x)
- `autoSubjectSize` - Automatically adjust to keep subject at 40% frame height
- `off` - No automatic zoom changes

**Key Properties:**
- `zoomFactor: CGFloat` - Current zoom (0.5 - 6.0)
- `mode: ZoomMode` - Current zoom mode
- `isSearching: Bool` - True when searching for target

**Auto Subject Size:**
- Target: 40% of frame height
- Tolerance: ±10%
- Adjustment: Gentle (0.5x error factor)

**Search Mode:**
- Activates when target expected but not found (10+ frames)
- Only zooms in if in `autoSubjectSize` mode
- Resets when target found or outside FOV

**FOV Calculation:**
- `currentHFOV: Double` - Preset-based horizontal FOV
  - `ultraWide` (0.5x): 100° (ultra-wide anchor)
  - `wide` (1.0x): 78° (main anchor)
  - `twoX` (2.0x): 45° (tele anchor)
  - `fourX` (4.0x): 25° (long tele anchor)
- ✅ **NOW INTEGRATED**: GPS uses `zoomController.currentHFOV` for dynamic FOV calculations

### 6. **CameraSessionManager** (`CameraSessionManager.swift`)
**Purpose:** Centralized camera session management

**Responsibilities:**
- Camera input/output configuration
- Preview layer management
- Video recording
- Orientation handling
- Autofocus/exposure configuration

**Outputs:**
1. **AVCaptureVideoDataOutput** - For Vision processing
2. **AVCaptureMovieFileOutput** - For video recording
3. **AVCaptureVideoPreviewLayer** - For on-screen preview

**Key Methods:**
- `setupSession()` - Configure camera session
- `setVideoFrameDelegate(_:)` - Set Vision delegate
- `startRecording()` / `stopRecording()` - Video recording
- `updateOrientation()` - Handle device rotation
- `setZoom(_:)` - Control zoom level

**Critical Fix:**
- Delegate must be set **after** session setup, or stored and applied during setup
- Otherwise Vision frames won't be delivered

---

## GPS Calibration System

### Two-Step Calibration Process

#### Step 1: Rig Calibration (Phone)
**Purpose:** Establish where the tripod/rig is located

**Process:**
1. User stands at/near the rig
2. Taps "📍 Calibrate Rig" button on phone
3. System samples GPS for 7 seconds
4. Filters and averages samples
5. Stores result in `rigCalibratedCoord`

**Location:** `RigLocationManager.startRigCalibration()`

#### Step 2: Center Calibration (Watch)
**Purpose:** Establish where "perfect center" is in front of camera

**Process:**
1. User stands in front of camera where they want "center"
2. Taps "🎯 Calibrate Center" button on Watch
3. Watch samples GPS for 7 seconds
4. Averages samples
5. Sends result to phone via WatchConnectivity
6. Phone stores in `watchCalibratedCoord`

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
   - Calculate `expectedX` from GPS
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
3. **Drift Fail-Safe (NEW):**
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

### Detailed Implementation Steps

#### Step 1: Compute Expected Screen X
```swift
let expectedX = computeExpectedXFromGPS(
    rigCoord: rigCalibratedCoord ?? rigLocation,
    watchCoord: watchLocation,
    calibratedBearing: calibratedBearing,
    currentCameraHeading: servoAngleToHeading(api.currentAngle)
)
```

**Returns:**
- `CGFloat?` (0..1) if target should be in FOV
- `nil` if target should be outside FOV

**Calculation:**
- Computes bearing from rig to watch location
- Compares to calibrated forward bearing
- Maps angle difference to screen X position (0..1)
- Returns `nil` if outside camera FOV (±30° for 60° HFOV)

#### Step 2: GPS Gating (Searching/Lost States Only)
If `expectedX != nil`:
1. Set `faceTracker.expectedX = expectedX`
2. Vision processes frame with GPS gating enabled
3. Each detected person scored:
   - **GPS Score** (50%): Distance from expected X
   - **Continuity Score** (35%): Distance from previous position
   - **Size Score** (15%): Bounding box area
4. Best person selected based on combined score

#### Step 3: State-Specific Tracking Decision

**Searching/Lost States (GPS-First Logic):**
1. **Check GPS Quality:**
   - If GPS is not good → fall back to Vision-only if available
   - If GPS is good → proceed with GPS-first
2. **GPS + Vision Alignment:**
   - **If both GPS expectedX (in FOV) AND Vision target exist:**
     - Calculate difference: `abs(visionX - gpsX)`
     - **If difference < 8% (match threshold):**
       - Vision and GPS agree → Vision takes control (`applyVisionFollower()`)
     - **If difference ≥ 8%:**
       - Vision not aligned → GPS drives servo (`trackWithWatchGPS()`)
   - **If GPS good but no Vision OR outside FOV:**
     - GPS-only tracking (`trackWithWatchGPS()`)

**Locked State:**
- **Always**: Use `applyVisionFollower()` - pure Vision tracking
- **GPS**: Only updates trust metrics (telemetry), does NOT move servo
- **Drift Monitoring**: If Vision drifts >30% from GPS for 15+ frames, drop lock → `.searching`

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

// Deadband: ignore tiny movements near center
if abs(offset) < 0.02 { return }  // 2% of screen width

// Convert offset to angle change
let gain: CGFloat = 8.0
var step = offset * gain * servoMirror  // degrees left/right

// Clamp step size
let maxStep: CGFloat = 4.0
step = max(-maxStep, min(maxStep, step))

// Apply to servo
let newAngle = clampAngle(currentAngle + step)
sendServoAngle(newAngle)
```

**Key Parameters:**
- **Deadband:** 0.02 (2% of screen) - prevents jitter near center
- **Gain:** 8.0 - converts normalized offset to degrees
- **Max Step:** 4.0° - limits movement per frame
- **Servo Mirror:** -1.0 - mirrors servo direction (change to 1.0 for normal)
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

## Tracking State Machine

### Overview
The tracking state machine provides intelligent state management for GPS+AI fusion mode, ensuring Vision has full control when a strong lock is established, while using GPS fusion during search and recovery phases.

### States

#### `.searching` - Initial Search Phase
- **Purpose:** Finding and acquiring the target
- **Behavior:** Uses full GPS+AI fusion
  - GPS computes expected screen position
  - Vision uses GPS gating for person selection
  - GPS can move the servo to help find target
  - If Vision finds person, starts counting toward lock

#### `.locked` - Strong Visual Lock ⭐
- **Purpose:** Maintain precise Vision-based tracking
- **Behavior:** **Vision has 100% control**
  - GPS does NOT move the servo
  - Pure Vision-based tracking (same as AI mode)
  - GPS still participates in selection/gating, but no movement
  - Ensures smooth, responsive tracking once lock is established
- **Transition:** After 12 consecutive frames with vision target (~1.2s at 10Hz)

#### `.lost` - Target Lost
- **Purpose:** Reacquire lost target using GPS
- **Behavior:** Uses GPS to search and reacquire
  - GPS can move the servo to search
  - Vision detection triggers return to searching state
  - Will transition back to searching when Vision reacquires
- **Transition:** After 8 consecutive frames without vision target (~0.8s at 10Hz)

### State Transitions

```
SEARCHING → LOCKED
  Trigger: 12 consecutive frames with vision target
  Log: "🔒 Entering LOCKED state"

LOCKED → LOST
  Trigger: 8 consecutive frames without vision target
  Log: "❗️ Lost target – entering LOST state"

LOST → SEARCHING
  Trigger: Vision target reacquired
  Log: "🔍 Vision reacquired – back to SEARCHING"
```

### Implementation Details

**State Variables:**
- `trackState: TrackState` - Current state (.searching, .locked, .lost)
- `consecutiveLockFrames: Int` - Frames with vision target
- `consecutiveLostFrames: Int` - Frames without vision target

**Thresholds:**
- `lockFramesThreshold = 12` - Frames needed for searching → locked
- `lostFramesThreshold = 8` - Frames needed for locked → lost

**Key Methods:**
- `updateTrackState(hasVisionTarget:)` - Updates state based on vision detection
- `gpsAiSearchingTick()` - Searching state behavior
- `gpsAiLockedTick()` - Locked state behavior (Vision-only)
- `gpsAiLostTick()` - Lost state behavior

### Coordinate Consistency

**Critical Fix:** Both AI mode and locked state use the same `applyVisionFollower()` function to ensure:
- Identical coordinate system (non-mirrored X: `x - 0.5`)
- Same deadband (2%), gain (8.0), max step (4.0°), and servo mirror (-1.0)
- No sudden flips or inconsistencies when transitioning states

### Safety Features

- **Angle Clamping:** All servo angles clamped to 15-165° range (not 0-180°) to avoid physical limits
- **State Reset:** State resets to `.searching` when switching modes or turning tracking off
- **Consistent Helpers:** All angle calculations use `clampAngle()` and `sendServoAngle()` helpers

### Benefits

1. **Smooth Tracking:** Once locked, Vision has full control without GPS interference
2. **Robust Recovery:** GPS helps reacquire when target is lost
3. **Intelligent Search:** GPS guides initial acquisition efficiently
4. **No Coordinate Conflicts:** Shared vision follower ensures consistency

---

## GPS Trust Metrics

### Overview
GPS trust metrics provide real-time telemetry on the alignment between GPS predictions and Vision detections. This enables the system to assess GPS reliability and, in future steps, dynamically adjust GPS influence based on measured quality.

### Purpose
- **Telemetry Only (Step 1):** Currently collects and logs GPS quality data
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

### Configuration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `gpsEMAAlpha` | 0.05 | EMA smoothing factor (smaller = smoother) |
| `gpsMaxScreenErrorForTrust` | 0.25 | Max error treated as "very bad" (25% screen width) |
| `gpsMinSamplesForTrust` | 30 | Minimum samples before trust > 0 |

### Reset Behavior

GPS metrics reset when:
- Tracking mode changes away from GPS+AI
- Tracking is turned off
- Ensures telemetry is session-scoped

### Current Status

**Step 1 (Current):** Telemetry only - no behavior changes
- Metrics are collected and logged
- `gpsTrust` is computed but not yet used
- `gpsBias` is measured but not yet applied

**Future Steps:**
- **Step 2:** Use `gpsBias` to correct GPS predictions
- **Step 3:** Use `gpsTrust` for dynamic GPS gating
- **Step 4:** Use `gpsTrust` to adjust search behavior

---

## Key Algorithms

### 1. Servo Angle Calculation (GPS Mode)

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

// Apply deadband
let deadband: CGFloat = 0.02            // 2% of screen
if abs(offset) < deadband { return }     // Don't move if close to center

// Convert to angle change
let gain: CGFloat = 8.0                 // Converts offset to angle change
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
let alpha: CGFloat = 0.3
let newCenter = CGPoint(
    x: prev.x * (1 - alpha) + raw.x * alpha,
    y: prev.y * (1 - alpha) + raw.y * alpha
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
Smooth Position
    ↓
faceCenter (Published)
    ↓
CameraScreen.trackWithCameraAI()
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
Exponential Smoothing
    ↓
smoothedLocation (Published)
    ↓
CameraScreen.trackWithWatchGPS()
    ↓
servoAngleForCurrentGPS()
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
└──────┬───────┘    └──────┬───────┘
       │                   │
       └─────────┬─────────┘
                 │
                 ▼
         ┌───────────────┐
         │ GPS Gating    │
         │ + Scoring     │
         └───────┬───────┘
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

---

## Configuration Parameters

### Tracking Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Tracking tick interval | 0.1s (10 Hz) | How often tracking loop runs |
| AI deadband | 2% | Don't move if within 2% of center |
| AI gain | 8 | Converts offset to angle change |
| AI max step | 4° | Maximum angle change per tick |
| Servo mirror | -1.0 | Servo direction multiplier (1.0 = normal, -1.0 = mirrored) |
| Vision smoothing alpha | 0.3 | Low-pass filter strength |
| Vision min confidence | 0.5 | Minimum detection confidence |

### GPS Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| GPS smoothing alpha | 0.4 | Exponential smoothing strength |
| Max stale age | 2s | GPS considered stale after 2s |
| GPS max step (close) | 3° | Fine-tuning step size |
| GPS max step (medium) | 5° | Medium distance step size |
| GPS max step (far) | 8° | Large distance step size |
| GPS deadband | 0.5° | Don't move if within 0.5° |

### Calibration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Calibration duration | 7s | How long to sample GPS |
| Sample interval | 0.3s | GPS sample frequency |
| Max accuracy | 20m | Reject samples with worse accuracy |
| Max age | 3s | Reject samples older than 3s |
| Min accuracy clamp | 3m | Prevent single point dominance |

### GPS+AI Fusion Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| GPS score weight | 50% | How much GPS proximity matters (for GPS gating) |
| Continuity weight | 35% | How much position continuity matters (for GPS gating) |
| Size weight | 15% | How much size (distance) matters (for GPS gating) |
| GPS gate threshold | 30% | Max distance from expected X (for GPS gating) |
| Continuity threshold | 20% | Max distance for continuity bonus (for GPS gating) |
| Camera HFOV | Dynamic | Horizontal field of view (preset-based: ultraWide=100°, wide=78°, mid=60°, tele2=45°, tele3=30°) |
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
| Min zoom | 1.0x | Minimum zoom level |
| Max zoom | 4.0x | Maximum zoom level |
| Target subject height | 40% | Auto-zoom target height |
| Height tolerance | ±10% | Auto-zoom tolerance |
| Zoom step | 0.1x | Incremental zoom change |
| Search threshold | 10 frames | Frames before search mode |

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

---

## Debugging Tips

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

### Servo Not Moving
1. Verify network connection to ESP32
2. Check `PanRigAPI.track(angle:)` is being called
3. Verify angle is within 15-165° range (safe clamping range)
4. Check deadband isn't preventing movement

---

## Video Recording Settings

### Resolution Options

The system supports two resolution modes:

| Mode | Resolution | Use Case |
|------|------------|----------|
| `hd1080` | 1920×1080 | Default, good balance of quality and performance |
| `uhd4K` | 3840×2160 | Maximum quality, larger files |

### Frame Rate

Locked to **30 FPS** for consistent quality and smooth tracking.

### Switching Resolution

```swift
// In CameraSessionManager
cameraManager.setResolution(.uhd4K)  // Switch to 4K
cameraManager.setResolution(.hd1080) // Switch to 1080p
```

**Note**: Resolution cannot be changed while recording. The toggle is disabled during active recording.

### UI Location

Resolution toggle is available in the **System Panel** (tap ^ button in bottom-right).

### Key Properties (CameraSessionManager)

- `resolution: CaptureResolution` - Current resolution setting
- `targetFPS: Double` - Target frame rate (default: 30)
- `currentResolutionDisplay: String` - Published display string

### Important Notes

1. **4K requires iPhone 6s or later**
2. **Resolution changes restart the capture session** (brief pause)
3. **All tracking math uses normalized 0-1 coordinates** - resolution change doesn't affect tracking
4. **Vision processing uses the same resolution** - 4K provides more detail for detection

---

## Future Enhancements

### Potential Improvements
1. **Multi-person tracking**: Track multiple people simultaneously
2. **Predictive tracking**: Use velocity to predict future position
3. **Dynamic zoom**: Adjust zoom based on subject distance
4. **Stabilization**: Add software stabilization for smoother video
5. **HDR recording**: Support HDR when available
6. **Lens switching**: Support telephoto lens for zoomed tracking

---

**Last Updated:** 2024
**Version:** 1.5 (GPS-First Fusion Logic - Searching/Lost states use GPS as primary driver, Locked state includes drift fail-safe)

