import Foundation
import CoreGraphics

/// Stores per-lens horizontal center bias in degrees.
/// Positive = nudge tracking to the RIGHT, negative = LEFT.
final class LensCalibrationManager: ObservableObject {
    static let shared = LensCalibrationManager()
    
    @Published private var biases: [String: CGFloat] = [:]
    
    private init() {
        loadFromDefaults()
    }
    
    // MARK: - Public API
    
    func bias(for preset: ZoomPreset) -> CGFloat {
        let k = key(for: preset)
        return biases[k] ?? 0.0
    }
    
    func setBias(_ value: CGFloat, for preset: ZoomPreset) {
        let k = key(for: preset)
        biases[k] = value
        UserDefaults.standard.set(Double(value), forKey: k)
    }
    
    func adjustBias(for preset: ZoomPreset, delta: CGFloat) {
        let current = bias(for: preset)
        let updated = current + delta
        setBias(updated, for: preset)
        print("🎯 Updated center bias for \(preset.rawValue): \(updated)°")
    }
    
    // MARK: - Private
    
    private func key(for preset: ZoomPreset) -> String {
        "LensCenterBias.\(preset.rawValue)"
    }
    
    private func loadFromDefaults() {
        // Seed from UserDefaults if present
        for preset in ZoomPreset.allCases {
            let k = key(for: preset)
            if let stored = UserDefaults.standard.object(forKey: k) as? Double {
                biases[k] = CGFloat(stored)
            }
        }
    }
}


