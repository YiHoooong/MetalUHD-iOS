import SwiftUI

/// Diagnostics and the raw run log, in a native grouped list.
struct LogView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    var body: some View {
        NavigationView {
            List {
                Section {
                    LabeledContent("Device", value: vm.deviceDescription)
                    LabeledContent("Last launch", value: vm.lastLaunchDescription)
                    LabeledContent("Pairing", value: vm.pairingReady ? "ready" : "missing")
                    LabeledContent("LocalDevVPN", value: vpnDescription)
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    if vm.log.isEmpty {
                        Text("No log yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
                    }
                } header: {
                    Text("Log")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { vm.log.removeAll() }
                }
            }
            .onAppear { vm.refreshVPNStatus() }
        }
    }

    private var vpnDescription: String {
        switch vm.vpnConnected {
        case .none: return "—"
        case .some(true): return String(localized: "connected")
        case .some(false): return String(localized: "offline")
        }
    }
}
