import SwiftUI

@main
struct SurfCamWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    print("SurfCamWatchApp: App appeared")
                }
        }
    }
}

