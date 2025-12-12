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

    // Color/size lock state
    private var targetColor: SIMD3<Float>?
    private var targetColorStrength: Float = 0.0
    private var lastColorBox: CGRect?

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
                DispatchQueue.main.async {
                    self.faceCenter = nil
                    self.smoothedCenter = nil
                    self.allDetections = []
                    self.targetBoundingBox = nil
                    // Don't clear currentTargetID - keep it for when they reappear
                }
                return
            }

            // Choose best detection using scoring
            let previous = self.smoothedCenter
            let chosen: PersonDetection
            
            let pixelBufferRef = pixelBuffer
            if gpsGating, let expX = gpsExpectedX {
                // GPS-gated selection: score each person (with color/size)
                chosen = self.pickBestTarget(
                    candidates: detections,
                    expectedX: expX,
                    previousCenter: previous,
                    pixelBuffer: pixelBufferRef
                )
            } else {
                // No GPS: use scoring without GPS bias (expectedX nil)
                chosen = self.pickBestTarget(
                    candidates: detections,
                    expectedX: nil,
                    previousCenter: previous,
                    pixelBuffer: pixelBufferRef
                )
            }

            let rawCenter = CGPoint(x: chosen.x, y: chosen.y)

            // Low-pass filter to smooth jitter
            // Make X more reactive while keeping Y smoothing
            let alphaX: CGFloat = 0.5   // more responsive horizontally
            let alphaY: CGFloat = 0.3   // keep vertical smoothing
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

        let wGPS: CGFloat   = 0.25
        let wCont: CGFloat  = 0.30
        let wSize: CGFloat  = 0.25
        let wColor: CGFloat = 0.20

        return wGPS * gpsScore
             + wCont * continuityScore
             + wSize * sizeScore
             + wColor * colorScore
    }
    
    /// Pick the best target from candidates using GPS gating
    private func pickBestTarget(
        candidates: [PersonDetection],
        expectedX: CGFloat?,
        previousCenter: CGPoint?,
        pixelBuffer: CVPixelBuffer?
    ) -> PersonDetection {
        guard !candidates.isEmpty else {
            fatalError("pickBestTarget called with empty candidates")
        }
        
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

        // Publish normalized bbox as baseline size via callback
        let width = detection.width
        let height = detection.height
        onSubjectSizeLocked?(width, height)

        print("✅ Locked subject color + size. width=\(width), height=\(height)")
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
