import SwiftUI

/// Diagnostics and the raw run log.
struct LogView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    diagnosticsCard
                    logCard
                }
                .padding()
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { vm.log.removeAll() }
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.subheadline.weight(.medium))
            diagnosticRow("Device", vm.deviceDescription)
            diagnosticRow("Last launch", vm.lastLaunchDescription)
            diagnosticRow("Pairing", vm.pairingReady ? "ready" : "missing")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func diagnosticRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(name))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            if vm.log.isEmpty {
                Text("No log yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
