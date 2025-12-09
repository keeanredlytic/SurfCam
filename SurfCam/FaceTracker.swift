import Foundation
import Vision
import CoreMedia
import ImageIO
import UIKit

/// Represents a detected person with scoring information
struct PersonDetection: Identifiable {
    let id: UUID
    let x: CGFloat           // center x, normalized 0..1
    let y: CGFloat           // center y, normalized 0..1
    let width: CGFloat       // normalized width
    let height: CGFloat      // normalized height
    let confidence: Float
    
    var area: CGFloat { width * height }
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
            
            if gpsGating, let expX = gpsExpectedX {
                // GPS-gated selection: score each person
                chosen = self.pickBestTarget(
                    candidates: detections,
                    expectedX: expX,
                    previousCenter: previous
                )
            } else if let prev = previous {
                // No GPS: use position continuity
                chosen = detections.min(by: { a, b in
                    let da = hypot(a.x - prev.x, a.y - prev.y)
                    let db = hypot(b.x - prev.x, b.y - prev.y)
                    return da < db
                })!
            } else {
                // First frame: just pick the largest box
                chosen = detections.max(by: { $0.area < $1.area })!
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
    private func scorePerson(
        _ person: PersonDetection,
        expectedX: CGFloat,
        previousCenter: CGPoint?
    ) -> Double {
        // GPS proximity score (0..1)
        var gpsScore = 0.0
        let dx = abs(person.x - expectedX)
        // If they're within 30% of screen width from where GPS says:
        if dx < 0.3 {
            gpsScore = 1.0 - Double(dx / 0.3)  // 1 at exact, 0 at edge
        }
        
        // Continuity score: prefer whoever we were tracking last time
        var continuityScore = 0.0
        if let prev = previousCenter {
            let dist = hypot(person.x - prev.x, person.y - prev.y)
            // If within 20% of screen from previous position, give continuity bonus
            if dist < 0.2 {
                continuityScore = 1.0 - Double(dist / 0.2)
            }
        }
        
        // Size score: favor closer (larger) people
        let sizeScore = min(1.0, Double(person.area / 0.1))  // Normalize by ~10% screen area
        
        // Weighted sum - GPS is most important when available
        return 0.50 * gpsScore +
               0.35 * continuityScore +
               0.15 * sizeScore
    }
    
    /// Pick the best target from candidates using GPS gating
    private func pickBestTarget(
        candidates: [PersonDetection],
        expectedX: CGFloat,
        previousCenter: CGPoint?
    ) -> PersonDetection {
        guard !candidates.isEmpty else {
            fatalError("pickBestTarget called with empty candidates")
        }
        
        return candidates.max { a, b in
            scorePerson(a, expectedX: expectedX, previousCenter: previousCenter)
            <
            scorePerson(b, expectedX: expectedX, previousCenter: previousCenter)
        }!
    }
}
