import SwiftUI

struct CenterCalibrationOverlay: View {
    @ObservedObject var calibration = LensCalibrationManager.shared
    let currentPreset: ZoomPreset?
    
    var body: some View {
        guard let preset = currentPreset else {
            return AnyView(EmptyView())
        }
        
        let bias = calibration.bias(for: preset)
        
        return AnyView(
            HStack(spacing: 8) {
                Button("−") {
                    calibration.adjustBias(for: preset, delta: -0.05) // 0.05° step
                }
                .buttonStyle(.borderless)
                
                Text(String(format: "%@  %.2f°", preset.displayName, bias))
                    .font(.system(size: 12, weight: .semibold))
                
                Button("+") {
                    calibration.adjustBias(for: preset, delta: 0.05)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color.black.opacity(0.6))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .padding(.top, 16)
            .padding(.trailing, 16)
        )
    }
}


