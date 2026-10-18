import SwiftUI

/// Diagnostics and the raw run log.
struct LogView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    var body: some View {
        NavigationView {
            List {
                Section {
                    row { LabeledContent("Device", value: vm.deviceDescription) }
                    row { LabeledContent("Last launch", value: vm.lastLaunchDescription) }
                    row { LabeledContent("Pairing", value: vm.pairingReady ? "ready" : "missing") }
                    row { LabeledContent("LocalDevVPN", value: vpnDescription) }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    if vm.log.isEmpty {
                        row {
                            Text("No log yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
                            .cardWidthListSeparator()
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

    @ViewBuilder
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().cardWidthListSeparator()
    }

    private var vpnDescription: String {
        switch vm.vpnConnected {
        case .none: return "—"
        case .some(true): return String(localized: "connected")
        case .some(false): return String(localized: "offline")
        }
    }
}
