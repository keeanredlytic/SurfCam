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
- `TrackingMode.cameraAI` (AI-only): auto-starts, Vision controls servo.
- `TrackingMode.gpsAI` (fusion): state machine; in `.locked`, AI controls servo; GPS servo currently disabled/archived.
- `TrackingMode.watchGPS` (GPS-only): GPS servo disabled/archived; Vision not used for servo.
- `TrackingMode.off`: no tracking.

---

## State Machine (CameraScreen)
- States: `.searching`, `.locked`, `.lost`
- Thresholds: `lockFramesThreshold = 12`, `lostFramesThreshold = 8`, drift: 30% for 15 frames (only when fusion enabled).
- In `cameraAI`: state machine still runs for lock/lost bookkeeping but servo control is Vision only.

---

## Vision Follower (CameraScreen.applyVisionFollower)
```swift
private func applyVisionFollower(from faceCenter: CGPoint) {
    let x = faceCenter.x // 0..1
    let gain: CGFloat = 10.0
    let deadband: CGFloat = 0.02
    let maxStep: CGFloat = 4.0
    let servoMirror: CGFloat = -1.0
    let baseBiasDegrees: CGFloat = -0.39
    let lensBiasDegrees: CGFloat = {
        if let preset = zoomController?.currentPreset {
            return preset.lensCenterBiasDegrees
        } else { return 0.0 }
    }()
    let totalBiasDegrees = baseBiasDegrees + lensBiasDegrees
    let centerBiasNorm = totalBiasDegrees / gain
    let offset = (x + centerBiasNorm) - 0.5
    if abs(offset) < deadband { return }
    var step = offset * gain * servoMirror
    step = max(-maxStep, min(maxStep, step))
    let currentAngle = CGFloat(api.currentAngle)
    let newAngle = clampAngle(currentAngle + step) // 15–165
    sendServoAngle(Int(newAngle))
}
```
- Clamping: `clampAngle` enforces 15°–165°.
- Bias: base + per-lens bias via `LensCalibrationManager`.
- Mirror: servoMirror = -1.0 (Vision path).

---

## FaceTracker.swift (Vision Pipeline)
- Receives frames via `CameraSessionManager` video output.
- Detection: `VNDetectHumanRectanglesRequest`.
- Filtering: confidence ≥ 0.5.
- Scoring (when GPS gating enabled):
  - `score = 0.50 * gpsScore + 0.35 * continuityScore + 0.15 * sizeScore`
  - gpsScore = 1.0 if within 30% of expectedX, else decays.
  - continuityScore = 1.0 near previous center, decays with distance.
  - sizeScore based on bounding box area (larger = closer).
- Smoothing:
  - Horizontal: alphaX = 0.5
  - Vertical: alphaY = 0.3
  - `newCenter = prev * (1 - alpha) + raw * alpha`
- Published outputs:
  - `faceCenter: CGPoint?`
  - `targetBoundingBox: CGRect?` (normalized 0..1; set when target chosen, cleared on loss/reset)
  - `expectedX: CGFloat?` (when GPS gating is on)
  - `useGPSGating: Bool`
  - Tracking reset via `resetTracking()`.

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
}

// Smoothing (applied after detection)
let alphaX: CGFloat = 0.5   // horizontal
let alphaY: CGFloat = 0.3   // vertical
let newCenter = CGPoint(
    x: prev.x * (1 - alphaX) + raw.x * alphaX,
    y: prev.y * (1 - alphaY) + raw.y * alphaY
)

// Scoring (when GPS gating is on)
score = 0.50 * gpsScore + 0.35 * continuityScore + 0.15 * sizeScore
// gpsScore decays from 1.0 at |person.x - expectedX| == 0 to 0 past ~30% screen width.
// continuityScore decays with distance from previous center.
// sizeScore is proportional to bounding box area (capped).

// Target selection (GPS-gated)
func pickBestTarget(candidates: [PersonDetection], expectedX: CGFloat, previousCenter: CGPoint?) -> PersonDetection {
    return candidates.max {
        scorePerson($0, expectedX: expectedX, previousCenter: previousCenter) <
        scorePerson($1, expectedX: expectedX, previousCenter: previousCenter)
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

## Servo Clamping / Helpers (GPSHelpers.swift)
- `clampAngle` is in CameraScreen; servo safe range 15–165°.
- Legacy GPS servo helpers remain but GPS servo is disabled in code.

---

## Zoom (for AI)
- `ZoomController` presets: ultraWide05 (0.5x, HFOV 110°), wide1 (1x, 78°), tele2 (2x, 40°), tele4 (4x, 22°).
- AI uses normalized coordinates; zoom does not change math, only apparent FOV and detection quality.
- Lens center bias per preset via `LensCalibrationManager`.

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
    @Published var mode: ZoomMode = .fixed(1.0)
    var autoDistanceZoomFloor: CGFloat = 1.5
    private var lastZoomDistanceMeters: Double?
    private var basePresetWhenAutoStarted: ZoomPreset?

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

    // MARK: - Vision-driven subject-width auto zoom
    func updateZoomForSubjectWidth(
        normalizedWidth: CGFloat?,
        cameraManager: CameraSessionManager
    ) {
        guard case .autoSubjectWidth = mode else { return }
        guard let width = normalizedWidth else { return }

        let hardZoomIn: CGFloat  = 0.05
        let sweetMin: CGFloat    = 0.07
        let sweetMax: CGFloat    = 0.10
        let hardZoomOut: CGFloat = 0.14

        let current = zoomFactor
        var targetZoom = current

        if width < hardZoomIn {
            targetZoom = current * 1.35
        } else if width < sweetMin {
            targetZoom = current * 1.10
        } else if width > hardZoomOut {
            targetZoom = current * 0.70
        } else if width > sweetMax {
            targetZoom = current * 0.90
        } else {
            return
        }

        let minFactor: CGFloat = 0.5
        let maxFactor: CGFloat = 24.0  // logical cap; device clamp applies
        targetZoom = max(minFactor, min(maxFactor, targetZoom))

        let alpha: CGFloat = 0.25
        var newZoom = current + alpha * (targetZoom - current)
        let maxDeltaPerTick: CGFloat = 0.20
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
  - calls `applyVisionFollower`
  - smooths `targetBoundingBox.width` into `smoothedSubjectWidth`
  - calls `zoomController.updateZoomForSubjectWidth(...)` (Vision-driven auto zoom)
- `trackWithGPSAIFusion()`:
  - `.searching`/`.lost`: currently no GPS servo (disabled); Vision can run if face present.
  - `.locked`: Vision-only servo via `applyVisionFollower`; GPS drift telemetry only.
- `tickTracking()` runs at 20 Hz; GPS-triggered ticks also fire via WatchGPSTracker callback.

### CameraScreen Vision auto-zoom integration (code)
```swift
// State
private var smoothedSubjectWidth: CGFloat?
private var subjectWidthFrameCounter: Int = 0

private func trackWithCameraAI() {
    guard let faceCenter = faceTracker.faceCenter else {
        smoothedSubjectWidth = nil
        return
    }

    // 1) Horizontal tracking (servo)
    applyVisionFollower(from: faceCenter)

    // 2) Smooth subject width from Vision bbox
    if let bbox = faceTracker.targetBoundingBox {
        let rawWidth = bbox.width       // 0..1 normalized
        let alpha: CGFloat = 0.4
        if let prev = smoothedSubjectWidth {
            smoothedSubjectWidth = prev * (1 - alpha) + rawWidth * alpha
        } else {
            smoothedSubjectWidth = rawWidth
        }
        subjectWidthFrameCounter &+= 1
        if subjectWidthFrameCounter % 30 == 0, let w = smoothedSubjectWidth {
            print("🔍 Subject width (smoothed): \(String(format: \"%.3f\", w))")
        }
    } else {
        smoothedSubjectWidth = nil
    }

    // 3) Vision-driven auto zoom
    if let width = smoothedSubjectWidth {
        zoomController.updateZoomForSubjectWidth(
            normalizedWidth: width,
            cameraManager: cameraManager
        )
    }
}
```

---

## Safety / Limits
- Vision deadband: 0.02 (2% screen), gain 10, maxStep 4°/tick.
- Servo angle clamp: 15–165°.
- Center bias: -0.39° base + lens-specific bias (UserDefaults via LensCalibrationManager).
- Mirror: servoMirror = -1.0 (Vision path).

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
  - Sweet zone: ~7–10% of frame width; no change inside.
  - Hard/soft actions: <5% → *1.35, <7% → *1.10; >14% → *0.70, >10% → *0.90.
  - Smoothing: α=0.25 toward target, maxΔ=0.20x/tick, ignores <0.01 changes.
  - Range: logical 0.5–24x (device clamp applies).
- Device clamping: CameraSessionManager clamps to device minAvailableVideoZoomFactor … min(maxAvailableVideoZoomFactor, 24x).

## Lens Bias
- `LensCalibrationManager` stores per-preset center bias (degrees). Applied in Vision follower as baseBias + per-lens bias.

## CameraSessionManager.swift (zoom)
- setZoom() clamps to device min/max (cap 24x) and syncs back to ZoomController.
- selects best back camera (triple → dual-wide → wide).

## UI Hooks
- Preset buttons call `applyPreset`.
- Auto Zoom button toggles `ZoomMode.autoSubjectWidth` (Vision-based).
- Distance debug label shows meters/feet when GPS valid.

## Disabled / Archived (Zoom + GPS Servo)
- GPS servo path is disabled in code; archived in `ARCHIVED_GPS_SERVO_LOGIC.md`.
- AutoSubjectSize logic exists but is not invoked in the tracking loop.

---

This document captures the full AI tracking behavior as of now, with GPS servo disabled for rework. Use it as the source of truth when refactoring or re-enabling GPS-driven movement.

