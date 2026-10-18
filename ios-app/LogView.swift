import SwiftUI

/// Full-screen run log, so the HUD page stays short.
struct LogView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    var body: some View {
        NavigationView {
            ScrollView {
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
}
