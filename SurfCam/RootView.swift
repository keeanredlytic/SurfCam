import SwiftUI

struct RootView: View {
    @StateObject private var api = PanRigAPI()
    @StateObject private var faceTracker = FaceTracker()
    @StateObject private var rigLocationManager = RigLocationManager()
    @StateObject private var gpsTracker = WatchGPSTracker()
    @StateObject private var zoomController = ZoomController()
    @StateObject private var cameraManager = CameraSessionManager()
    
    var body: some View {
        TabView {
            CameraScreen(api: api,
                         faceTracker: faceTracker,
                         rigLocationManager: rigLocationManager,
                         gpsTracker: gpsTracker,
                         zoomController: zoomController,
                         cameraManager: cameraManager)
                .tabItem {
                    Image(systemName: "video.fill")
                    Text("Camera")
                }

            ControlsScreen(api: api, faceTracker: faceTracker)
                .tabItem {
                    Image(systemName: "slider.horizontal.3")
                    Text("Controls")
                }
            
            SettingsScreen(zoomController: zoomController)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
    }
}

