# SurfCam Tracking & AI System Documentation

## 📋 Table of Contents
1. [System Architecture](#system-architecture)
2. [Tracking Modes](#tracking-modes)
3. [Core Components](#core-components)
4. [GPS Calibration System](#gps-calibration-system)
5. [GPS+AI Fusion Algorithm](#gpsai-fusion-algorithm)
6. [Key Algorithms](#key-algorithms)
7. [Data Flow](#data-flow)
8. [Configuration Parameters](#configuration-parameters)

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
3. Calculates offset from screen center (normalized 0..1)
4. Converts offset to servo angle change
5. Applies deadband to prevent jitter

**Key Parameters:**
- Deadband: 10% of screen width
- Gain: 8 (converts offset to angle change)
- Max step: 4° per tick (prevents overshoot)

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
- `cameraHFOV: Double = 60` - Horizontal field of view in degrees
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
- `zoomFactor: CGFloat` - Current zoom (1.0 - 4.0)
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
- `currentHFOV: Double` - Approximate horizontal FOV
  - 1.0x - 1.4x: 60° (wide)
  - 1.4x - 2.4x: 45° (mid)
  - 2.4x+: 30° (tele)

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
The fusion mode combines GPS prediction with Vision confirmation for robust tracking.

### Algorithm Flow

```
┌─────────────────────────────────────────────────┐
│ 1. Compute Expected X from GPS                  │
│    expectedX = expectedXFromGPS(...)            │
└───────────────┬─────────────────────────────────┘
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

### Detailed Steps

#### Step 1: Compute Expected Screen X
```swift
let expectedX = computeExpectedXFromGPS(
    rigCoord: rigCalibratedCoord ?? rigLocation,
    watchCoord: watchLocation,
    calibratedBearing: calibratedBearing,
    currentCameraHeading: servoAngleToHeading(...)
)
```

**Returns:**
- `CGFloat?` (0..1) if target should be in FOV
- `nil` if target should be outside FOV

#### Step 2: GPS Gating (if in FOV)
If `expectedX != nil`:
1. Set `faceTracker.expectedX = expectedX`
2. Vision processes frame with GPS gating enabled
3. Each detected person scored:
   - **GPS Score** (50%): Distance from expected X
   - **Continuity Score** (35%): Distance from previous position
   - **Size Score** (15%): Bounding box area
4. Best person selected based on combined score

#### Step 3: Tracking Decision
- **If Vision found person**: Use AI tracking (`trackWithCameraAI()`)
- **If Vision can't find**: Pan toward `expectedX` (`panTowardExpectedX()`)
- **If GPS says outside FOV**: Use GPS-only tracking (`trackWithWatchGPS()`)

### GPS Gating Scoring Formula
```swift
score = 0.50 * gpsScore + 0.35 * continuityScore + 0.15 * sizeScore

where:
  gpsScore = 1.0 - (|person.x - expectedX| / 0.3)  // Clamped to [0, 1]
  continuityScore = 1.0 - (distance / 0.2)  // Clamped to [0, 1]
  sizeScore = min(1.0, person.area / 0.1)
```

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

```swift
// Vision gives us normalized center (0..1, origin at bottom-left)
let mirroredX = 1 - face.x  // Flip for preview mirroring
let offset = (mirroredX - 0.5) * 2.0  // Convert to -1..+1

// Apply deadband
if abs(offset) < 0.10 { return }  // Don't move if close to center

// Convert to angle change
let gain: Double = 8
let rawStep = Double(offset) * gain
let step = max(-4, min(4, rawStep))  // Clamp to ±4°

// Apply to servo
let newAngle = max(0, min(180, currentAngle + step))
```

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
| AI deadband | 10% | Don't move if within 10% of center |
| AI gain | 8 | Converts offset to angle change |
| AI max step | 4° | Maximum angle change per tick |
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
| GPS score weight | 50% | How much GPS proximity matters |
| Continuity weight | 35% | How much position continuity matters |
| Size weight | 15% | How much size (distance) matters |
| GPS gate threshold | 30% | Max distance from expected X |
| Continuity threshold | 20% | Max distance for continuity bonus |
| Camera HFOV | 60° | Horizontal field of view (wide lens) |

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
3. Verify angle is within 0-180 range
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
**Version:** 1.1

