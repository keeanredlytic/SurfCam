import SwiftUI

struct ContentView: View {
    @StateObject private var api = PanRigAPI()
    @StateObject private var faceTracker = FaceTracker()
    @StateObject private var cameraManager = CameraSessionManager()
    @State private var angle: Double = 90  // 0–180
    
    var body: some View {
        ZStack {
            Color(.sRGB, red: 17/255, green: 24/255, blue: 39/255, opacity: 1)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                ZStack {
                    CameraView(faceTracker: faceTracker, cameraManager: cameraManager)
                        .frame(height: 300)
                        .clipped()
                    
                    // Overlay: center line + face position marker
                    GeometryReader { geo in
                        let width = geo.size.width
                        let height = geo.size.height
                        let centerX = width / 2
                        
                        // center vertical line
                        Path { path in
                            path.move(to: CGPoint(x: centerX, y: 0))
                            path.addLine(to: CGPoint(x: centerX, y: height))
                        }
                        .stroke(Color.yellow.opacity(0.6), lineWidth: 2)
                        
                        if let face = faceTracker.faceCenter {
                            // Vision: (0,0) bottom-left. View: (0,0) top-left.
                            let xPos = face.x * width
                            let yPos = (1 - face.y) * height  // flip Y
                            
                            Circle()
                                .fill(Color.red.opacity(0.8))
                                .frame(width: 18, height: 18)
                                .position(x: xPos, y: yPos)
                        }
                    }
                    .allowsHitTesting(false)
                }
                
                // Controls card
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PanRig")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Connect to Wi-Fi \"PanRig\" (password 12345678).")
                            .font(.footnote)
                            .foregroundColor(Color(.systemGray3))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pan angle")
                                .foregroundColor(Color(.systemGray3))
                            Spacer()
                            Text("\(Int(angle))°")
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        }
                        
                        Slider(value: $angle, in: 0...180, step: 1) { isEditing in
                            if !isEditing {
                                api.trackPan(angle: Int(angle))
                            }
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Button("Left (0°)") {
                            angle = 0
                            api.trackPan(angle: 0)
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Center (90°)") {
                            angle = 90
                            api.centerPan()
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Right (180°)") {
                            angle = 180
                            api.trackPan(angle: 180)
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                    
                    HStack(spacing: 8) {
                        Button("Step -15°") {
                            api.stepPan(delta: -15)
                            angle = max(0, angle - 15)
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Step +15°") {
                            api.stepPan(delta: 15)
                            angle = min(180, angle + 15)
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                    
                    Text(api.statusText)
                        .font(.caption)
                        .foregroundColor(Color(.systemGray3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let face = faceTracker.faceCenter {
                        let faceX = face.x
                        let offset = (faceX - 0.5) * 2.0   // -1 .. +1
                        Text(String(format: "Face offset: %.2f (− left, + right)", offset))
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Face not detected")
                            .font(.caption)
                            .foregroundColor(Color(.systemGray3))
                    }
                    
                    Spacer()
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.sRGB, red: 31/255, green: 41/255, blue: 55/255, opacity: 1))
                        .shadow(radius: 16)
                )
                .padding()
            }
        }
    }
}

#Preview {
    ContentView()
}
