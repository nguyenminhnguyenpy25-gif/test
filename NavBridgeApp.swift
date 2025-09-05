import SwiftUI

@main
struct NavBridgeApp: App {
    @StateObject var nav = NavController()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(nav)
        }
    }
}