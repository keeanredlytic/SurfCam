import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var zoomController: ZoomController
    
    var body: some View {
        ZStack {
            Color(.sRGB, red: 17/255, green: 24/255, blue: 39/255, opacity: 1)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Configure tracking and camera options")
                            .font(.footnote)
                            .foregroundColor(Color(.systemGray3))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    
                    // Camera Zoom Settings
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Auto-Zoom")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Text("Coming Soon")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(6)
                        }
                        
                        Text("Automatically zoom in when GPS indicates target is in frame but Vision can't detect them.")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        // Zoom controls (disabled for now)
                        VStack(spacing: 8) {
                            HStack {
                                Text("Current Zoom")
                                    .foregroundColor(Color(.systemGray3))
                                Spacer()
                                Text(String(format: "%.1fx", zoomController.zoomFactor))
                                    .foregroundColor(.white)
                                    .fontWeight(.semibold)
                            }
                            
                            Slider(value: Binding(
                                get: { zoomController.zoomFactor },
                                set: { newVal in
                                    zoomController.setZoomLevel(newVal)
                                }
                            ), in: zoomController.minZoom...zoomController.maxZoom, step: 0.1)
                            .disabled(true)  // Disabled for now
                            
                            HStack(spacing: 8) {
                                Button("Reset") {
                                    zoomController.resetZoom()
                                }
                                .buttonStyle(PillButtonStyle())
                                .disabled(true)  // Disabled for now
                                
                                Button("1.5x") {
                                    zoomController.setZoomLevel(1.5)
                                }
                                .buttonStyle(PillButtonStyle())
                                .disabled(true)  // Disabled for now
                                
                                Button("2.0x") {
                                    zoomController.setZoomLevel(2.0)
                                }
                                .buttonStyle(PillButtonStyle())
                                .disabled(true)  // Disabled for now
                            }
                        }
                        .opacity(0.5)  // Visual indication it's disabled
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.sRGB, red: 31/255, green: 41/255, blue: 55/255, opacity: 1))
                    )
                    .padding(.horizontal)
                    
                    Spacer()
                }
                .padding(.vertical)
            }
        }
    }
}

