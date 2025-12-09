# Zoom System Documentation

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture & Components](#architecture--components)
3. [Zoom Modes](#zoom-modes)
4. [Integration with Tracking Systems](#integration-with-tracking-systems)
5. [GPS & Field of View (FOV) Calculations](#gps--field-of-view-fov-calculations)
6. [How Zoom Affects Tracking](#how-zoom-affects-tracking)
7. [Implementation Details](#implementation-details)
8. [Extending the Zoom System](#extending-the-zoom-system)
9. [Configuration Parameters](#configuration-parameters)
10. [Common Patterns & Best Practices](#common-patterns--best-practices)
11. [Troubleshooting](#troubleshooting)

---

## Overview

The zoom system in SurfCam provides flexible camera zoom control with multiple modes. The infrastructure exists for tracking integration and automatic FOV calculations, but **only fixed zoom mode via UI buttons is currently active**.

### ⚠️ Current Implementation Status

**✅ Working:**
- **Zoom Presets**: Preset-based zoom system (0.5x, 1x, 2x, 4x via UI buttons)
- **Fixed Zoom Mode**: Presets map to fixed zoom factors
- **Dynamic FOV**: `ZoomController.currentHFOV` uses preset-based FOV (100°, 78°, 60°, 45°, 30°)
- **GPS Dynamic FOV**: ✅ **NOW INTEGRATED** - GPS uses `zoomController.currentHFOV` for accurate expectedX calculations
- Basic zoom infrastructure (`ZoomController`, `CameraSessionManager.setZoom()`)

**❌ Not Integrated (but code exists):**
- Auto subject size mode (logic exists, not called from tracking loop)
- Search mode for GPS+AI (functions exist, not called)

### Key Features

- **Zoom Presets**: `ZoomPreset` enum (ultraWide, wide, twoX, fourX) with logical factors and FOV anchors
- **Preset-Based FOV**: Each preset has its own horizontal FOV (ultraWide=100°, wide=78°, mid=60°, tele2=45°, tele3=30°)
- **GPS Integration**: GPS calculations now use dynamic FOV based on current preset
- **Multiple Zoom Modes**: Fixed zoom levels (via presets), auto subject size, and manual control
- **Smooth Transitions**: Prevents zoom ramping conflicts
- **Search Mode**: Functions exist for automatic zoom-in when target expected but not found (not called)

---

## Architecture & Components

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    CameraScreen                          │
│  (Main Controller - Owns ZoomController)               │
└──────────────┬──────────────────────────────────────────┘
               │
               │ @ObservedObject
               ▼
┌─────────────────────────────────────────────────────────┐
│                 ZoomController                           │
│  - Manages zoom modes and state                          │
│  - Provides FOV calculations                             │
│  - Handles search mode logic                             │
└──────────────┬──────────────────────────────────────────┘
               │
               │ Uses
               ├─────────────────┐
               │                 │
               ▼                 ▼
┌──────────────────────┐  ┌──────────────────────┐
│ CameraSessionManager │  │   FaceTracker         │
│  - setZoom()         │  │  - Subject height    │
│  - videoDevice       │  │  - Detection data   │
└──────────────────────┘  └──────────────────────┘
```

### Core Files

| Component | File | Responsibility |
|-----------|------|----------------|
| **ZoomPreset** | `ZoomController.swift` | Enum defining zoom presets (ultraWide, wide, mid, tele2, tele3) |
| **ZoomController** | `ZoomController.swift` | Zoom mode management, preset handling, FOV calculations, search mode |
| **CameraSessionManager** | `CameraSessionManager.swift` | Direct AVFoundation zoom control, device-safe zoom clamping |
| **CameraScreen** | `CameraScreen.swift` | UI integration, preset button controls |
| **GPSHelpers** | `GPSHelpers.swift` | GPS → expectedX calculations (uses dynamic FOV parameter) |

### Zoom Preset System

**Enum:** `ZoomPreset` (in `ZoomController.swift`)

The system uses preset-based zoom with the following structure:

```swift
enum ZoomPreset: String, CaseIterable, Identifiable {
    case ultraWide   // 0.5x logical factor, 100° FOV
    case wide        // 1.0x logical factor, 78° FOV
    case mid         // 1.5x logical factor, 60° FOV
    case tele2       // 2.0x logical factor, 45° FOV
    case tele3       // 3.0x logical factor, 30° FOV
}
```

**Key Properties:**
- `logicalFactor: CGFloat` - The zoom factor to request (device may clamp)
- `displayName: String` - UI display name ("0.5x", "1x", "2x", "4x")
- `currentPreset: ZoomPreset` - Tracks active preset in `ZoomController`
- `applyPreset(_:)` - Updates mode, zoomFactor, and FOV based on preset

---

## Zoom Modes

### 1. Fixed Zoom Mode (Preset-Based)

**Enum Value:** `ZoomMode.fixed(CGFloat)`

**Description:** Locks zoom to a specific factor via zoom presets

**Zoom Presets:**
The system uses `ZoomPreset` enum with the following presets:

| Preset | Logical Factor | Display Name | FOV |
|--------|---------------|--------------|-----|
| `ultraWide` | 0.5x | "0.5x" | 100° |
| `wide` | 1.0x | "1x" | 78° |
| `twoX` | 2.0x | "2x" | 45° |
| `fourX` | 4.0x | "4x" | 25° |

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

**Code Example:**
```swift
// Apply preset (updates mode, zoomFactor, and FOV)
zoomController.applyPreset(.twoX)   // Sets to 2x, FOV = 45°

// Or manually:
zoomController.mode = .fixed(2.0)
zoomController.setZoomLevel(2.0)
```

### 2. Auto Subject Size Mode

**Enum Value:** `ZoomMode.autoSubjectSize`

**Description:** Automatically adjusts zoom to keep the tracked subject at ~40% of frame height

**Behavior:**
- Monitors subject height from Vision detections
- Adjusts zoom when subject is outside tolerance (±10%)
- Gentle adjustments (0.5x error multiplier) to prevent oscillation
- Only adjusts if subject height > 5% (ignores tiny detections)

**Algorithm:**
```swift
let error = targetSubjectHeight - currentHeight  // target = 0.4 (40%)
if abs(error) < subjectHeightTolerance { return }  // tolerance = 0.1

let zoomAdjustment = error * 0.5  // Gentle adjustment
let newZoom = clamp(zoomFactor + zoomAdjustment, min: 1.0, max: 4.0)
```

**Use Cases:**
- Maintaining consistent subject size
- Automatic framing
- Hands-free operation

**Limitations:**
- Requires Vision detection to work
- May oscillate if subject moves erratically
- Subject must be detectable (not too small/large)

### 3. Off Mode

**Enum Value:** `ZoomMode.off`

**Description:** Disables all automatic zoom changes from code

**Behavior:**
- No zoom adjustments from tracking system
- User can still manually control zoom (if UI supports it)
- Useful for manual control or testing

**Use Cases:**
- Manual zoom control
- Testing/debugging
- When zoom should be completely static

---

## Integration with Tracking Systems

### AI Mode (Pure Vision Tracking)

**Current Implementation:**
- **Fixed Mode**: Zoom can be set via UI buttons (1x, 1.5x, 2x, 3x)
- **Auto Subject Size Mode**: **NOT CURRENTLY INTEGRATED** - The functionality exists in `ZoomController` but `updateZoom()` is never called
- **Off Mode**: No zoom changes from code

**Key Point:** Vision tracking uses normalized coordinates (0..1), so zoom changes don't affect the tracking math directly. However, zoom affects:
- Detection accuracy (higher zoom = better detail, narrower FOV)
- Subject size in frame

**Code Flow:**
```swift
// In CameraScreen.tickTracking() for AI mode:
trackWithCameraAI()  // Uses applyVisionFollower()
// NOTE: Auto-zoom is NOT currently called
// To enable: add zoomController.updateZoom(for: targetHeight) in tracking loop
```

### GPS Mode (Pure GPS Tracking)

**Current Implementation:**
- **Fixed Mode**: Zoom can be set via UI buttons
- **Auto/Off Modes**: Not used (no Vision data for auto-zoom)

**Key Point:** GPS tracking calculates absolute angles, not screen positions, so zoom doesn't directly affect GPS tracking math. However, zoom affects:
- FOV calculations (used for determining if target is in frame)
- Visual framing of the shot

**FOV Impact:**
```swift
// ✅ NOW INTEGRATED: GPS uses dynamic FOV from zoom preset
let expectedX = expectedXFromGPS(
    rigCoord: rig,
    watchCoord: watch,
    calibratedBearing: calBearing,
    currentCameraHeading: heading,
    cameraHFOV: zoomController.currentHFOV  // ← Dynamic FOV based on preset
)
```

**How It Works:**
- Each zoom preset has its own FOV (ultraWide=100°, wide=78°, mid=60°, tele2=45°, tele3=30°)
- GPS calculations use the current preset's FOV to determine if target is in frame
- Narrower FOV (higher zoom) = more precise GPS gating
- Wider FOV (lower zoom) = more forgiving GPS gating

### GPS+AI Fusion Mode

**Current Implementation:**
- **Fixed Mode**: Zoom can be set via UI buttons
- **Auto Subject Size Mode**: **NOT CURRENTLY INTEGRATED**
- **Search Mode**: **NOT CURRENTLY INTEGRATED** - Functions exist but are never called

**⚠️ Important Notes:**
- The search mode functions (`targetExpectedButNotFound()`, `targetFound()`, `targetOutsideFOV()`) exist in `ZoomController` but are **NOT called** from `CameraScreen`
- Auto-zoom (`updateZoom()`) is **NOT called** in the tracking loop
- Zoom currently only works via manual UI button presses

**What EXISTS but is NOT USED:**
```swift
// These functions exist in ZoomController but are never called:
zoomController.targetExpectedButNotFound()  // Would zoom in when target expected but not found
zoomController.targetFound()               // Would reset search state
zoomController.targetOutsideFOV()         // Would reset search state
zoomController.updateZoom(for: height)    // Would auto-adjust zoom based on subject size
```

**To Enable Search Mode:**
```swift
// In runExistingGPSAIBehavior():
if let expectedX = expectedX {
    if hasVisionTarget {
        zoomController.targetFound()  // Add this
        trackWithCameraAI()
    } else {
        zoomController.targetExpectedButNotFound()  // Add this
        panTowardExpectedX(expectedX)
    }
} else {
    zoomController.targetOutsideFOV()  // Add this
    trackWithWatchGPS()
}
```

**State-Specific Behavior (If Integrated):**

| State | Zoom Behavior (If Enabled) |
|-------|----------------------------|
| **Searching** | Auto-zoom would zoom in if target expected but not found (in auto mode) |
| **Locked** | Auto-zoom would adjust based on subject size (in auto mode) |
| **Lost** | Same as searching (zoom in to help reacquire) |

---

## GPS & Field of View (FOV) Calculations

### Horizontal Field of View (HFOV)

The system uses horizontal field of view to map GPS bearings to screen positions. Zoom level directly affects FOV.

### Current Implementation

**Location:** `ZoomController.currentHFOV`

**Preset-Based FOV Table:**
```swift
var currentHFOV: Double {
    switch currentPreset {
    case .ultraWide: return 100   // 0.5x anchor
    case .wide:      return 78    // 1x anchor
    case .twoX:      return 45    // 2x anchor
    case .fourX:     return 25    // 4x anchor
    }
}
```

**✅ NOW INTEGRATED:** GPS calculations now use this dynamic FOV.

**GPS FOV Usage:**
- `expectedXFromGPS()` accepts `cameraHFOV: Double` as a parameter
- `computeExpectedXFromGPS()` passes `zoomController.currentHFOV`
- GPS expectedX calculations now accurately reflect current zoom preset

**Note:** These are reasonable approximations and can be tuned later. Real FOV depends on:
- Physical lens (0.5x ultra-wide, 1x wide, 2x telephoto)
- Digital zoom factor
- Device model

### GPS Expected X Calculation

**Function:** `expectedXFromGPS()` in `GPSHelpers.swift`

**How FOV is Used:**
```swift
func expectedXFromGPS(
    rigCoord: CLLocationCoordinate2D,
    watchCoord: CLLocationCoordinate2D,
    calibratedBearing: Double,
    currentCameraHeading: Double,
    cameraHFOV: Double  // ← Dynamic FOV parameter
) -> CGFloat? {
    // 1. Calculate bearing from rig to watch
    let brg = bearing(from: rigCoord, to: watchCoord)
    
    // 2. Calculate angle difference from camera heading (normalize -180..+180)
    var delta = brg - currentCameraHeading
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    
    // 3. Check if outside FOV
    if abs(delta) > cameraHFOV / 2 {  // ← Uses dynamic FOV
        return nil  // Target outside frame
    }
    
    // 4. Map angle to screen X (0..1)
    let normalized = (delta + cameraHFOV / 2) / cameraHFOV
    return CGFloat(max(0, min(1, normalized)))
}
```

**✅ NOW INTEGRATED:** GPS uses dynamic FOV from zoom preset.

**Current State:**
- `GPSHelpers.swift`: `expectedXFromGPS()` accepts `cameraHFOV: Double` parameter
- `ZoomController.currentHFOV`: Preset-based FOV calculation (ultraWide=100°, wide=78°, mid=60°, tele2=45°, tele3=30°)
- `computeExpectedXFromGPS()`: Passes `zoomController.currentHFOV` to `expectedXFromGPS()`

**Implementation:**
```swift
// In CameraScreen.computeExpectedXFromGPS():
let hfov = zoomController.currentHFOV  // Get FOV from current preset

return expectedXFromGPS(
    rigCoord: rig,
    watchCoord: watch,
    calibratedBearing: calBearing,
    currentCameraHeading: currentHeading,
    cameraHFOV: hfov  // ← Pass dynamic FOV
)
```

---

## How Zoom Affects Tracking

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

**Example:**
```
At 1.0x zoom: FOV = 60° → ±30° from center = full frame
At 3.0x zoom: FOV = 30° → ±15° from center = full frame

If GPS says target is at +20° from center:
- At 1.0x: expectedX ≈ 0.67 (in frame)
- At 3.0x: expectedX ≈ 1.33 (outside frame, clamped to 1.0)
```

### GPS+AI Fusion

**Zoom Impact:**
- **Search Mode**: Zoom in when target expected but not found
- **Locked Mode**: Auto-zoom adjusts based on subject size
- **FOV Accuracy**: Critical for GPS expectedX calculations

**State Machine Interaction:**
- **Searching**: Can zoom in to help Vision find target
- **Locked**: Normal auto-zoom operation
- **Lost**: Can zoom in to help reacquire

---

## Implementation Details

### ZoomController Class

**Key Properties:**
```swift
@Published var zoomFactor: CGFloat = 1.0      // Current zoom level
@Published var mode: ZoomMode = .fixed(1.0)   // Current mode
@Published var isSearching = false            // Search mode state

weak var videoDevice: AVCaptureDevice?         // Direct device access
weak var cameraManager: CameraSessionManager? // Preferred access method
```

**Key Methods:**
```swift
// Mode-based updates
func updateZoom(for targetHeight: CGFloat?)  // Called each frame

// Search mode
func targetExpectedButNotFound()              // Call when GPS says in-frame but no Vision
func targetFound()                            // Call when Vision finds target
func targetOutsideFOV()                        // Call when GPS says outside FOV

// Direct control
func setZoomLevel(_ level: CGFloat)           // Set specific zoom
func gentlyZoomIn()                           // Increment by zoomStep
func gentlyZoomOutToward(_ target: CGFloat)   // Decrement toward target
func resetZoom()                              // Reset to defaultZoom

// FOV
var currentHFOV: Double                       // Get current FOV approximation
```

### CameraSessionManager Integration

**Zoom Control:**
```swift
func setZoom(_ factor: CGFloat) {
    guard let device = videoDevice else { return }
    do {
        try device.lockForConfiguration()
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 6.0)
        let clampedZoom = max(1.0, min(factor, maxZoom))
        device.videoZoomFactor = clampedZoom
        device.unlockForConfiguration()
    } catch {
        print("Zoom error: \(error)")
    }
}
```

**Key Points:**
- Respects device max zoom (typically 3-6x)
- Clamps to safe range (1.0 - maxZoom)
- Must lock device for configuration
- No callback needed (device updates immediately)

### ZoomController.setZoom() Method

**Implementation:**
```swift
func setZoomLevel(_ level: CGFloat) {
    let clamped = max(minZoom, min(maxZoom, level))
    
    // Prefer cameraManager, fall back to direct device access
    if let manager = cameraManager {
        manager.setZoom(clamped)
        DispatchQueue.main.async {
            self.zoomFactor = clamped
        }
    } else if let device = videoDevice {
        setZoom(clamped, on: device)
    }
}
```

**Key Points:**
- Clamps to minZoom/maxZoom range
- Updates `zoomFactor` on main thread
- Prevents zoom ramping conflicts with `isRampingVideoZoom` check

### Search Mode Implementation

**State Tracking:**
```swift
private var framesWithoutTarget = 0
private let searchThreshold = 10  // frames

func targetExpectedButNotFound() {
    framesWithoutTarget += 1
    if framesWithoutTarget > searchThreshold {
        isSearching = true
        if case .autoSubjectSize = mode {
            gentlyZoomIn()  // Only in auto mode
        }
    }
}

func targetFound() {
    framesWithoutTarget = 0
    isSearching = false
}
```

**⚠️ NOT CURRENTLY INTEGRATED:** The search mode functions exist but are **NOT called** in the tracking code.

**What SHOULD be added (but isn't currently):**
```swift
// In runExistingGPSAIBehavior():
if let expectedX = expectedX {
    // GPS says target should be in FOV
    if hasVisionTarget {
        zoomController.targetFound()  // ← NOT CURRENTLY CALLED
        trackWithCameraAI()
    } else {
        zoomController.targetExpectedButNotFound()  // ← NOT CURRENTLY CALLED
        panTowardExpectedX(expectedX)
    }
} else {
    // GPS says outside FOV
    zoomController.targetOutsideFOV()  // ← NOT CURRENTLY CALLED
    trackWithWatchGPS()
}
```

**Current State:**
- Search mode functions exist in `ZoomController`
- They are **never called** from `CameraScreen`
- Auto-zoom search behavior is **not active**

---

## Current Implementation Status

### What's Actually Working

✅ **Zoom Presets System**
- `ZoomPreset` enum with 5 presets (ultraWide, wide, mid, tele2, tele3)
- UI buttons (0.5x, 1x, 2x, 4x) map to presets
- `applyPreset()` updates mode, zoomFactor, and FOV
- Preset-based FOV calculation (`currentHFOV`)

✅ **Fixed Zoom Mode (Preset-Based)**
- UI buttons work via `zoomController.applyPreset()`
- Each preset has logical factor and FOV mapping
- Zoom changes apply immediately

✅ **Dynamic FOV for GPS** ✅ **NOW INTEGRATED**
- `ZoomController.currentHFOV` uses preset-based FOV
- GPS `expectedXFromGPS()` accepts `cameraHFOV` parameter
- `computeExpectedXFromGPS()` passes `zoomController.currentHFOV`
- GPS calculations now accurately reflect current zoom preset

✅ **ZoomController Infrastructure**
- All zoom modes defined
- Search mode functions exist
- Auto-zoom logic exists

### What's NOT Currently Integrated

❌ **Auto Subject Size Mode**
- Logic exists in `ZoomController.updateZoom()`
- **NOT called** from tracking loop
- To enable: Add `zoomController.updateZoom(for: targetHeight)` in `tickTracking()`

❌ **Search Mode (GPS+AI)**
- Functions exist: `targetExpectedButNotFound()`, `targetFound()`, `targetOutsideFOV()`
- **NOT called** from `runExistingGPSAIBehavior()`
- To enable: Add calls in GPS+AI tracking logic

### Summary

The zoom system now has **preset-based zoom with dynamic FOV integration for GPS**. Fixed zoom mode via presets is fully active, and GPS calculations use the correct FOV for each preset. Auto-zoom and search mode exist but are not integrated into the tracking loop.

---

## Extending the Zoom System

### Adding a New Zoom Mode

**Step 1: Extend ZoomMode Enum**
```swift
enum ZoomMode: Equatable {
    case fixed(CGFloat)
    case autoSubjectSize
    case off
    case yourNewMode(parameters)  // Add your mode
    
    var displayName: String {
        switch self {
        // ... existing cases ...
        case .yourNewMode: return "Your Mode"
        }
    }
}
```

**Step 2: Add Mode Logic to updateZoom()**
```swift
func updateZoom(for targetHeight: CGFloat?) {
    switch mode {
    // ... existing cases ...
    case .yourNewMode(let params):
        // Your zoom logic here
        break
    }
}
```

**Step 3: Update UI (if needed)**
```swift
// In CameraScreen.swift
// Add UI controls for your new mode
```

### Improving FOV Calculations

**Current Limitation:** FOV is approximated based on zoom factor only.

**Better Approach:** Use actual device/lens information.

**Option 1: Device-Specific FOV Table**
```swift
struct DeviceFOV {
    let ultraWide: Double    // 0.5x lens
    let wide: Double        // 1.0x lens
    let telephoto: Double   // 2.0x lens
}

// Per-device lookup
let deviceFOVs: [String: DeviceFOV] = [
    "iPhone 14 Pro": DeviceFOV(ultraWide: 120, wide: 78, telephoto: 45),
    // ... other devices ...
]

var currentHFOV: Double {
    // Get current lens (from AVCaptureDevice.activeFormat)
    // Apply digital zoom factor
    // Return accurate FOV
}
```

**Option 2: Dynamic FOV from AVFoundation**
```swift
var currentHFOV: Double {
    guard let device = videoDevice else { return 60 }
    // Use device.activeFormat properties
    // Calculate based on sensor size, focal length, etc.
}
```

**Option 3: Calibration-Based FOV**
```swift
// User calibrates FOV at different zoom levels
// Store in UserDefaults
// Use calibrated values
```

### Making GPS FOV Dynamic

**Current Issue:** `GPSHelpers.swift` uses hardcoded `cameraHFOV = 60`

**Fix:**
```swift
// In GPSHelpers.swift - remove hardcoded constant
// func expectedXFromGPS(...) becomes:
func expectedXFromGPS(
    rigCoord: CLLocationCoordinate2D,
    watchCoord: CLLocationCoordinate2D,
    calibratedBearing: Double,
    currentCameraHeading: Double,
    cameraHFOV: Double  // ← Add as parameter
) -> CGFloat? {
    // ... use cameraHFOV parameter instead of constant ...
}

// In CameraScreen.computeExpectedXFromGPS():
return expectedXFromGPS(
    rigCoord: rig,
    watchCoord: watch,
    calibratedBearing: calBearing,
    currentCameraHeading: currentHeading,
    cameraHFOV: zoomController.currentHFOV  // ← Pass dynamic FOV
)
```

### Adding Per-Lens Zoom Support

**Current:** Global `centerBiasDegrees` (though user mentioned per-lens support)

**Implementation:**
```swift
// In CameraScreen.swift
struct LensBias {
    let ultraWide: CGFloat = 0.0
    let wide: CGFloat = -0.39
    let telephoto: CGFloat = 0.0
}

private let lensBias = LensBias()

// In applyVisionFollower():
let currentLens = getCurrentLens()  // From device.activeFormat
let centerBiasDegrees = lensBias.value(for: currentLens)
```

### Adding Zoom Smoothing

**Current:** Instant zoom changes

**Implementation:**
```swift
class ZoomController {
    private var targetZoom: CGFloat = 1.0
    private var zoomVelocity: CGFloat = 0.0
    private let zoomSmoothing: CGFloat = 0.1  // Adjust for smoothness
    
    func setZoomLevel(_ level: CGFloat) {
        targetZoom = level
        // Smooth toward targetZoom each frame
    }
    
    func updateZoomSmoothing() {
        let error = targetZoom - zoomFactor
        zoomVelocity = zoomVelocity * (1 - zoomSmoothing) + error * zoomSmoothing
        let newZoom = zoomFactor + zoomVelocity
        applyZoom(newZoom)
    }
}
```

---

## Configuration Parameters

### ZoomController Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `minZoom` | 1.0x | Minimum zoom level |
| `maxZoom` | 4.0x | Maximum zoom level (clamped to device max) |
| `defaultZoom` | 1.0x | Default/reset zoom level |
| `zoomStep` | 0.1x | Incremental zoom change for gentle adjustments |

### Auto Subject Size Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `targetSubjectHeight` | 0.4 (40%) | Target subject height as fraction of frame |
| `subjectHeightTolerance` | 0.1 (±10%) | Tolerance before adjusting zoom |
| `zoomAdjustmentMultiplier` | 0.5 | How aggressively to adjust (error × multiplier) |
| `minSubjectHeight` | 0.05 (5%) | Ignore detections smaller than this |

### Search Mode Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `searchThreshold` | 10 frames | Frames without target before entering search mode |
| `searchZoomStep` | 0.1x | Zoom increment when searching (same as zoomStep) |

### FOV Preset Parameters

| Preset | Logical Factor | FOV | Description |
|--------|---------------|-----|-------------|
| ultraWide | 0.5x | 100° | Ultra-wide anchor |
| wide | 1.0x | 78° | Main lens anchor |
| twoX | 2.0x | 45° | Tele anchor |
| fourX | 4.0x | 25° | Long tele anchor |

**Note:** These are reasonable approximations and can be tuned later. Real FOV depends on device model and lens.

---

## Common Patterns & Best Practices

### 1. Always Check for Ramping

**Pattern:**
```swift
guard !device.isRampingVideoZoom else { return }
```

**Why:** Prevents conflicts if zoom is already changing.

### 2. Update zoomFactor on Main Thread

**Pattern:**
```swift
DispatchQueue.main.async {
    self.zoomFactor = clampedZoom
}
```

**Why:** `zoomFactor` is `@Published`, must update on main thread.

### 3. Clamp Zoom to Safe Range

**Pattern:**
```swift
let clamped = max(minZoom, min(maxZoom, level))
let deviceMax = device.activeFormat.videoMaxZoomFactor
let finalZoom = min(clamped, deviceMax)
```

**Why:** Prevents invalid zoom values and device errors.

### 4. Use CameraManager When Available

**Pattern:**
```swift
if let manager = cameraManager {
    manager.setZoom(clamped)
} else if let device = videoDevice {
    setZoom(clamped, on: device)
}
```

**Why:** CameraManager may have additional logic or state management.

### 5. Reset Search State Appropriately

**Pattern:**
```swift
// When target found:
zoomController.targetFound()

// When target outside FOV:
zoomController.targetOutsideFOV()

// When target expected but not found:
zoomController.targetExpectedButNotFound()
```

**Why:** Keeps search mode state accurate for GPS+AI fusion.

### 6. Don't Change Zoom During Critical Tracking

**Pattern:**
```swift
// In locked state, allow auto-zoom
// In searching state, only zoom in if target not found
// Avoid rapid zoom changes during active tracking
```

**Why:** Prevents tracking disruption from zoom changes.

---

## Troubleshooting

### Issue: Zoom Not Responding

**Symptoms:** Zoom buttons don't change zoom level

**Possible Causes:**
1. Device not locked for configuration
2. `videoDevice` is nil
3. `cameraManager` not set
4. Zoom value outside valid range

**Debug Steps:**
```swift
// Check device availability
print("Device: \(zoomController.videoDevice)")
print("CameraManager: \(zoomController.cameraManager)")

// Check zoom value
print("Requested zoom: \(level)")
print("Current zoom: \(zoomController.zoomFactor)")

// Check device max
print("Device max zoom: \(device.activeFormat.videoMaxZoomFactor)")
```

### Issue: Auto-Zoom Oscillating

**Symptoms:** Zoom constantly adjusting back and forth

**Possible Causes:**
1. `zoomAdjustmentMultiplier` too high
2. `subjectHeightTolerance` too small
3. Subject moving erratically
4. Vision detection jitter

**Solutions:**
- Reduce `zoomAdjustmentMultiplier` (currently 0.5, try 0.3)
- Increase `subjectHeightTolerance` (currently 0.1, try 0.15)
- Add hysteresis (different thresholds for zoom in vs zoom out)
- Increase Vision smoothing

### Issue: GPS ExpectedX Inaccurate at High Zoom

**Symptoms:** GPS says target should be in frame, but it's not

**Possible Causes:**
1. FOV approximation inaccurate at high zoom
2. Hardcoded FOV in GPSHelpers (60°) not matching actual FOV
3. Lens switching not accounted for

**Solutions:**
- Use `zoomController.currentHFOV` instead of hardcoded value
- Improve FOV calculation (see "Improving FOV Calculations" section)
- Calibrate FOV at different zoom levels

### Issue: Search Mode Not Triggering

**Symptoms:** Target expected but not found, but zoom doesn't increase

**Possible Causes:**
1. Not calling `targetExpectedButNotFound()`
2. `searchThreshold` too high
3. Not in auto mode
4. `framesWithoutTarget` resetting prematurely

**Debug Steps:**
```swift
// Check search state
print("Is searching: \(zoomController.isSearching)")
print("Frames without target: \(framesWithoutTarget)")

// Verify mode
print("Zoom mode: \(zoomController.mode)")

// Check if function is being called
print("targetExpectedButNotFound() called")
```

### Issue: Zoom Changes Disrupt Tracking

**Symptoms:** Tracking loses lock when zoom changes

**Possible Causes:**
1. Zoom changing too rapidly
2. Zoom changing during critical tracking moments
3. FOV change affecting GPS calculations

**Solutions:**
- Add zoom smoothing (see "Adding Zoom Smoothing" section)
- Pause auto-zoom during state transitions
- Update FOV calculations immediately when zoom changes

---

## File Locations

| Component | File Path |
|-----------|-----------|
| ZoomController | `SurfCam/ZoomController.swift` |
| CameraSessionManager zoom | `SurfCam/CameraSessionManager.swift` (setZoom method) |
| CameraScreen zoom UI | `SurfCam/CameraScreen.swift` (zoom buttons, integration) |
| GPS FOV usage | `SurfCam/GPSHelpers.swift` (expectedXFromGPS) |
| FaceTracker | `SurfCam/FaceTracker.swift` (subject height data) |

---

## Version History

**Version 1.0** - Initial documentation
- Complete zoom system overview
- All modes documented
- Integration patterns
- Extension guidelines

---

**Last Updated:** 2024
**Version:** 1.0 (Initial Comprehensive Zoom System Documentation)

