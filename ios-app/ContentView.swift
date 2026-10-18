import SwiftUI

/// Bottom tab bar: the HUD workflow, the raw run log, and everything about
/// pairing/tunnel in Settings.
struct ContentView: View {
    @ObservedObject private var vm = HUDViewModel.shared
    @State private var tab: Tab = .hud

    enum Tab: Hashable {
        case hud
        case log
        case settings
    }

    var body: some View {
        TabView(selection: $tab) {
            HUDHomeView()
                .tabItem { Label("HUD", systemImage: "speedometer") }
                .tag(Tab.hud)

            LogView()
                .tabItem { Label("Log", systemImage: "text.alignleft") }
                .tag(Tab.log)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear { vm.refreshPairingState() }
        .onOpenURL { url in
            // Documents opened with this app arrive here and, on a cold launch,
            // through AppDelegate.application(_:open:).
            if url.isFileURL { vm.adoptPairingFile(at: url) }
        }
    }
}
