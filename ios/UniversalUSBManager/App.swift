import SwiftUI

@main
struct UniversalUSBManagerApp: App {
    @StateObject private var queue = TransferQueue.shared
    @StateObject private var locations = LocationStore()
    @StateObject private var clipboard = Clipboard()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { HomeView() }.tabItem { Label("Storage", systemImage: "externaldrive") }
                QueueView().tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            }
            .environmentObject(queue)
            .environmentObject(locations)
            .environmentObject(clipboard)
        }
    }
}
