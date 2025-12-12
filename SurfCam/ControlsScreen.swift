import SwiftUI
import Network

struct ControlsScreen: View {
    @ObservedObject var api: PanRigAPI
    @ObservedObject var faceTracker: FaceTracker
    @State private var browser: NWBrowser?
    
    var body: some View {
        ZStack {
            Color(.sRGB, red: 17/255, green: 24/255, blue: 39/255, opacity: 1)
                .ignoresSafeArea()
            
            VStack {
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
                            Text("\(Int(api.currentPanAngle))°")
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        }
                        
                        Slider(value: Binding(
                            get: { api.currentPanAngle },
                            set: { newVal in
                                api.currentPanAngle = newVal
                                api.trackPan(angle: Int(newVal))
                            }
                        ), in: api.minPanAngle...api.maxPanAngle, step: 1)
                    }
                    
                    HStack(spacing: 8) {
                        Button("Left (0°)") {
                            api.trackPan(angle: 0)
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Center (90°)") {
                            api.centerPan()
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Right (180°)") {
                            api.trackPan(angle: 180)
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                    
                    HStack(spacing: 8) {
                        Button("Step -15°") {
                            api.stepPan(delta: -15)
                        }
                        .buttonStyle(PillButtonStyle())
                        
                        Button("Step +15°") {
                            api.stepPan(delta: 15)
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                    
                    Text(api.statusText)
                        .font(.caption)
                        .foregroundColor(Color(.systemGray3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Test connection button - triggers Local Network permission prompt
                    Button(action: {
                        triggerLocalNetworkPermission()
                        // Also try direct connection
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            api.testConnection()
                        }
                    }) {
                        HStack {
                            Image(systemName: "network")
                            Text("Test Connection")
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange)
                        .cornerRadius(10)
                    }
                    
                    Text("Tap 'Test Connection' to request network access")
                        .font(.caption2)
                        .foregroundColor(Color(.systemGray4))
                        .frame(maxWidth: .infinity, alignment: .center)
                    
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
        .onAppear {
            // Trigger permission prompt when screen appears
            triggerLocalNetworkPermission()
        }
    }
    
    // This triggers the Local Network permission prompt by browsing for Bonjour services
    private func triggerLocalNetworkPermission() {
        // Create a browser for HTTP services - this reliably triggers the permission prompt
        let params = NWParameters()
        params.includePeerToPeer = true
        
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Browser ready - Local Network permission granted")
            case .failed(let error):
                print("Browser failed: \(error)")
            case .waiting(let error):
                print("Browser waiting: \(error)")
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { results, changes in
            print("Found \(results.count) services on local network")
        }
        
        // Start browsing - this triggers the permission prompt
        browser.start(queue: .main)
        
        // Keep a reference so it doesn't get deallocated
        self.browser = browser
        
        // Stop after a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            browser.cancel()
        }
    }
}

// Simple pill-style button
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBlue))
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

