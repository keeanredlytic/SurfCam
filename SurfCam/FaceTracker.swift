import Foundation
import Vision
import CoreMedia
import ImageIO
import UIKit
import simd

/// Represents a detected person with scoring information
struct PersonDetection: Identifiable {
    let id: UUID
    let x: CGFloat           // center x, normalized 0..1
    let y: CGFloat           // center y, normalized 0..1
    let width: CGFloat       // normalized width
    let height: CGFloat      // normalized height
    let confidence: Float
    
    var area: CGFloat { width * height }
    var aspectRatio: CGFloat { width / max(height, 0.0001) } // avoid /0
}

class FaceTracker: ObservableObject {
    // Normalized 0–1 coords of the tracked target (body center)
    @Published var faceCenter: CGPoint? = nil
    
    // All detected people this frame (for GPS-gated selection)
    @Published var allDetections: [PersonDetection] = []
    
    // Currently tracked person ID (for continuity scoring)
    @Published var currentTargetID: UUID?

    // Bounding box of the current tracked person (normalized 0..1)
    @Published var targetBoundingBox: CGRect?

    // Subject lock bridge
    @Published var shouldLockSubject: Bool = false
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

    // Color/size lock state
    private var targetColor: SIMD3<Float>?
    private var targetColorStrength: Float = 0.0
    private var lastColorBox: CGRect?
    
    // Hard subject lock state
    private var lockedTargetID: UUID?
    private var isHardLocked: Bool = false
    private var framesSinceLockedSeen: Int = 0
    private let hardLockLostThreshold: Int = 20  // ~1s at 20 Hz (tune as needed)

    private let visionQueue = DispatchQueue(label: "FaceTracker.visionQueue")
    private var smoothedCenter: CGPoint? = nil
    
    // Cached orientation updated from main thread
    private var cachedOrientation: CGImagePropertyOrientation = .right
    
    // GPS gating support
    var expectedX: CGFloat?  // Set externally by tracking controller
    var useGPSGating = false

    /// Call this from the main thread to update the cached orientation
    func updateOrientation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOrientation()
            }
            return
        }
        
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        let interfaceOrientation = scene?.interfaceOrientation ?? .portrait

        switch interfaceOrientation {
        case .portrait:
            cachedOrientation = .right
        case .portraitUpsideDown:
            cachedOrientation = .left
        case .landscapeLeft:
            cachedOrientation = .down
        case .landscapeRight:
            cachedOrientation = .up
        default:
            cachedOrientation = .right
        }
    }
    
    /// Reset tracking state (call when switching modes)
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

    private var frameCount = 0

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Debug: confirm frames are being received (every 30 frames to avoid spam)
        frameCount += 1
        if frameCount % 30 == 0 {
            print("🟢 Vision processing frame \(frameCount)")
        }

        let exifOrientation = cachedOrientation
        let gpsExpectedX = expectedX
        let gpsGating = useGPSGating

        let request = VNDetectHumanRectanglesRequest { [weak self] request, _ in
            guard let self = self else { return }

            guard let results = request.results as? [VNHumanObservation] else {
                DispatchQueue.main.async {
                    self.faceCenter = nil
                    self.smoothedCenter = nil
                    self.allDetections = []
                }
                return
            }

            // Filter by confidence so we ignore super-weak blobs
            let minConfidence: VNConfidence = 0.5
            let candidates = results.filter { $0.confidence >= minConfidence }
            
            // Convert to PersonDetection structs
            let detections = candidates.map { obs -> PersonDetection in
                PersonDetection(
                    id: UUID(),  // New ID each frame (we use position for continuity)
                    x: obs.boundingBox.midX,
                    y: obs.boundingBox.midY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height,
                    confidence: obs.confidence
                )
            }
            
            guard !detections.isEmpty else {
                // Tracking-wise, we lost them this frame
                DispatchQueue.main.async {
                    self.faceCenter = nil
                    self.smoothedCenter = nil
                    self.allDetections = []
                    self.targetBoundingBox = nil
                    // Don't clear currentTargetID - keep it for when they reappear
                }
                
                // Keep isHardLocked / isColorLockActive as-is;
                // framesSinceLockedSeen should still be incremented in the outer logic.
                return
            }

            // Choose best detection using scoring (with hard lock support)
            let previous = self.smoothedCenter
            let pixelBufferRef = pixelBuffer
            let gpsExpectedXValue = gpsGating ? gpsExpectedX : nil
            
            var chosen: PersonDetection
            
            if isHardLocked, let lockedID = lockedTargetID {
                // Try to find the locked target in this frame
                if let lockedDetection = detections.first(where: { $0.id == lockedID }) {
                    // ✅ Still seeing the locked subject – use it and ONLY it
                    chosen = lockedDetection
                    framesSinceLockedSeen = 0
                    
                    // 🔵 Debug: hard lock center tracks this subject
                    DispatchQueue.main.async {
                        self.hardLockCenter = CGPoint(x: lockedDetection.x, y: lockedDetection.y)
                        self.isUsingColorReacquire = false
                    }
                } else {
                    // 🚨 Locked subject not detected in this frame
                    framesSinceLockedSeen &+= 1
                    
                    if framesSinceLockedSeen <= hardLockLostThreshold {
                        // Grace window – we are in color-heavy reacquire mode
                        DispatchQueue.main.async {
                            self.isUsingColorReacquire = true
                        }
                        
                        chosen = self.pickBestTarget(
                            candidates: detections,
                            expectedX: gpsExpectedXValue,
                            previousCenter: nil,      // continuity is unreliable here
                            pixelBuffer: pixelBufferRef
                        )
                        
                        // 🔵 Debug: hardLockCenter moves with chosen reacquire target
                        DispatchQueue.main.async {
                            self.hardLockCenter = CGPoint(x: chosen.x, y: chosen.y)
                        }
                    } else {
                        // Hard lock expires
                        print("⚠️ Hard lock expired after \(framesSinceLockedSeen) frames without subject.")
                        isHardLocked = false
                        lockedTargetID = nil
                        framesSinceLockedSeen = 0
                        
                        DispatchQueue.main.async {
                            self.isUsingColorReacquire = false
                            self.hardLockCenter = nil
                            self.isColorLockActive = false
                        }
                        
                        // Fallback to normal best-target behavior
                        chosen = self.pickBestTarget(
                            candidates: detections,
                            expectedX: gpsExpectedXValue,
                            previousCenter: previous,
                            pixelBuffer: pixelBufferRef
                        )
                    }
                }
            } else {
                // No hard lock – normal scoring-based choice
                framesSinceLockedSeen = 0
                DispatchQueue.main.async {
                    self.isUsingColorReacquire = false
                }
                chosen = self.pickBestTarget(
                    candidates: detections,
                    expectedX: gpsExpectedXValue,
                    previousCenter: previous,
                    pixelBuffer: pixelBufferRef
                )
            }

            let rawCenter = CGPoint(x: chosen.x, y: chosen.y)

            // Low-pass filter to smooth jitter
            // Make X more reactive while keeping Y smoothing
            let alphaX: CGFloat = 0.7   // more weight on new data → snappier pan
            let alphaY: CGFloat = 0.45  // slightly snappier tilt, still smooth-ish
            let newCenter: CGPoint
            if let prev = self.smoothedCenter {
                newCenter = CGPoint(
                    x: prev.x * (1 - alphaX) + rawCenter.x * alphaX,
                    y: prev.y * (1 - alphaY) + rawCenter.y * alphaY
                )
            } else {
                newCenter = rawCenter
            }

            DispatchQueue.main.async {
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
            
            // Handle explicit subject lock request (color + size baseline)
            if self.shouldLockSubject,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                self.lockColorAndSize(from: pixelBuffer, using: chosen)
                self.shouldLockSubject = false
            }
            }
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: exifOrientation,
            options: [:]
        )

        visionQueue.async {
            try? handler.perform([request])
        }
    }
    
    // MARK: - GPS-Gated Person Selection
    
    /// Score a person based on GPS proximity, continuity, and size
    private func computeColorScore(
        for person: PersonDetection,
        pixelBuffer: CVPixelBuffer?
    ) -> CGFloat {
        guard let target = targetColor,
              targetColorStrength > 0.1,
              let pixelBuffer = pixelBuffer else {
            return 0.0
        }

        let bbox = CGRect(
            x: person.x - person.width / 2,
            y: person.y - person.height / 2,
            width: person.width,
            height: person.height
        )

        guard let avg = averageColor(in: bbox, from: pixelBuffer) else { return 0.0 }
        let sim = colorSimilarity(target, avg) // 0..1
        let score = sim * targetColorStrength
        return CGFloat(score)
    }

    private func scorePerson(
        _ person: PersonDetection,
        expectedX: CGFloat?,
        previousCenter: CGPoint?,
        pixelBuffer: CVPixelBuffer?
    ) -> CGFloat {
        // GPS proximity score (0..1)
        var gpsScore: CGFloat = 0.0
        if let expX = expectedX {
            let dx = abs(person.x - expX)
            if dx < 0.3 {
                gpsScore = 1.0 - (dx / 0.3)  // 1 at exact, 0 at edge
            }
        }
        
        // Continuity score: prefer whoever we were tracking last time
        var continuityScore: CGFloat = 0.0
        if let prev = previousCenter {
            let dist = hypot(person.x - prev.x, person.y - prev.y)
            if dist < 0.2 {
                continuityScore = 1.0 - (dist / 0.2)
            }
        }
        
        // Size score: favor closer (larger) people; prone → width matters more
        let ar = person.aspectRatio
        let isProne = ar < 0.6
        let widthScore: CGFloat = min(1.0, person.width / 0.10)
        let areaScore: CGFloat  = min(1.0, person.area / 0.02)
        let sizeScore: CGFloat = isProne ? widthScore : areaScore

        // Color score based on locked targetColor
        let colorScore = computeColorScore(for: person, pixelBuffer: pixelBuffer)

        // Are we in a "reacquire" situation?
        // i.e. we have a locked color, but no reliable previous center.
        let hasPrevCenter = (previousCenter != nil)
        let hasColorLock = (targetColor != nil && targetColorStrength > 0.1)
        let isReacquiring = (!hasPrevCenter && hasColorLock)

        // Weights for normal vs reacquire
        let wGPS: CGFloat
        let wCont: CGFloat
        let wSize: CGFloat
        let wColor: CGFloat

        if isReacquiring {
            // Reacquire mode: lean hard on color, less on continuity (since we have none)
            wGPS  = 0.15   // still allow GPS gating a bit if present
            wCont = 0.10   // continuity is mostly useless with no previous center
            wSize = 0.30   // size still matters (closer person is likelier)
            wColor = 0.45  // 🔥 make color the main signal to reacquire the same surfer
        } else {
            // Normal tracking mode: more balanced, but with stronger color than before
            wGPS  = 0.20
            wCont = 0.25
            wSize = 0.20
            wColor = 0.35  // ⬆️ bumped from 0.20 → 0.35
        }

        // Final composite score
        return wGPS * gpsScore
             + wCont * continuityScore
             + wSize * sizeScore
             + wColor * colorScore
    }
    
    /// Pick the best target from candidates using scoring (GPS/color/size/continuity)
    /// Note: Hard lock logic is handled at the frame processing level, not here.
    private func pickBestTarget(
        candidates: [PersonDetection],
        expectedX: CGFloat?,
        previousCenter: CGPoint?,
        pixelBuffer: CVPixelBuffer?
    ) -> PersonDetection {
        guard !candidates.isEmpty else {
            fatalError("pickBestTarget called with empty candidates")
        }
        
        // Normal scoring: pick highest-scoring candidate
        return candidates.max { a, b in
            scorePerson(a, expectedX: expectedX, previousCenter: previousCenter, pixelBuffer: pixelBuffer)
            <
            scorePerson(b, expectedX: expectedX, previousCenter: previousCenter, pixelBuffer: pixelBuffer)
        }!
    }

    // MARK: - Explicit color + size lock
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

    // MARK: - Color sampling helpers
    private func averageColor(in bbox: CGRect, from pixelBuffer: CVPixelBuffer) -> SIMD3<Float>? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Convert normalized bbox → pixel coords and expand slightly
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
                // BGRA
                let b = Float(p[0])
                let g = Float(p[1])
                let r = Float(p[2])
                rSum += r; gSum += g; bSum += b
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return SIMD3<Float>(rSum / Float(count),
                            gSum / Float(count),
                            bSum / Float(count)) / 255.0
    }

    private func colorSimilarity(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let da = simd_normalize(a)
        let db = simd_normalize(b)
        let dot = max(0, simd_dot(da, db))
        return dot // 0..1
    }
}
