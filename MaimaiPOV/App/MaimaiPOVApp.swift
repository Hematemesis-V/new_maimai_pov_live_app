import SwiftUI

@main
struct MaimaiPOVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Phase2View()
        }
    }
}
