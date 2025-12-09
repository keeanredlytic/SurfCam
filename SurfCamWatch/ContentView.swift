import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager: WatchLocationManager
    
    init() {
        // Initialize location manager safely
        _locationManager = StateObject(wrappedValue: WatchLocationManager())
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
            Text("SurfCam GPS")
                .font(.headline)
            
            if let loc = locationManager.currentLocation {
                    VStack(spacing: 2) {
                    Text(String(format: "%.5f", loc.coordinate.latitude))
                            .font(.system(.caption2, design: .monospaced))
                    Text(String(format: "%.5f", loc.coordinate.longitude))
                            .font(.system(.caption2, design: .monospaced))
                        
                        // Accuracy indicator with color coding
                        HStack(spacing: 6) {
                            Text(String(format: "±%.1fm", locationManager.accuracy))
                                .font(.caption2)
                                .foregroundColor(accuracyColor)
                            
                            if locationManager.isTracking {
                                Text(String(format: "%.1f Hz", locationManager.updateRate))
                        .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                }
            } else {
                Text("No GPS")
                        .font(.caption)
                    .foregroundColor(.gray)
            }
            
                // Start/Stop tracking button
            Button(action: {
                if locationManager.isTracking {
                    locationManager.stop()
                } else {
                    locationManager.start()
                }
            }) {
                    HStack {
                        Image(systemName: locationManager.isTracking ? "stop.fill" : "location.fill")
                Text(locationManager.isTracking ? "Stop" : "Start")
                    }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(locationManager.isTracking ? .red : .green)
                
                if locationManager.isTracking {
                    Text("Workout active")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                // Center Calibration Section
                VStack(spacing: 6) {
                    Text("Center Calibration")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    if locationManager.isCalibrating {
                        // Show progress during calibration
                        VStack(spacing: 4) {
                            ProgressView(value: locationManager.calibrationProgress)
                            Text("\(locationManager.calibrationSampleCount) samples")
                                .font(.caption2)
                                .foregroundColor(.gray)
                            
                            Button("Cancel") {
                                locationManager.cancelCenterCalibration()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .font(.caption2)
                        }
                    } else {
                        Button(action: {
                            locationManager.startCenterCalibration()
                        }) {
                            HStack {
                                Image(systemName: "target")
                                Text("Calibrate Center")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        
                        Button(action: {
                            locationManager.startRigCalibrationFromWatch()
                        }) {
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                Text("Calibrate Rig (Watch)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        
                        // Show last calibration result
                        if let result = locationManager.lastCalibrationResult {
                            Text(result)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Text("Stand where center should be")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
        }
        .padding()
        }
    }
    
    // Color code accuracy: green < 5m, yellow 5-10m, red > 10m
    private var accuracyColor: Color {
        let acc = locationManager.accuracy
        if acc < 0 { return .gray }
        if acc <= 5 { return .green }
        if acc <= 10 { return .yellow }
        return .red
    }
}

#Preview {
    ContentView()
}

