import SwiftUI

@main
struct VPNGateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("VPN Gate", id: "main") {
            ContentView()
                .environmentObject(delegate.store)
                .environmentObject(delegate.vpn)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ServerStore()
    let vpn = VPNController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting the app also takes the tunnel down, so it never outlives its UI.
    func applicationWillTerminate(_ notification: Notification) {
        vpn.disconnectBlocking()
    }
}
