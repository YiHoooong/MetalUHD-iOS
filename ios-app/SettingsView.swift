import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything about getting a pairing file and reaching the loopback tunnel.
struct SettingsView: View {
    @ObservedObject private var vm = HUDViewModel.shared
    @ObservedObject private var pairing = PairingController.shared
    @State private var showImporter = false

    /// Pairing files come from other sideloaders, which do not agree on an
    /// extension. `.plist` covers an exported record; the rest are the names
    /// SideStore / LiveContainer / Jitterbug use.
    private static let pairingTypes: [UTType] = {
        var types: [UTType] = [.propertyList, .data]
        for ext in ["mobiledevicepairing", "mobilepairing", "plist"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }()

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    pairingCard
                    tunnelCard
                    aboutCard
                }
                .padding()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.refreshPairingState() }
        }
    }

    // MARK: pairing

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: vm.pairingReady ? "checkmark.seal.fill" : "person.badge.key")
                    .foregroundColor(vm.pairingReady ? .green : .orange)
                Text(LocalizedStringKey(vm.pairingReady ? "Pairing file ready" : "Pairing required"))
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            Text(LocalizedStringKey(vm.pairingReady
                 ? "A pairing file was found, so every action is available."
                 : "The exploit needs a pairing file. Pair this iPhone with itself below, or share an existing pairing file into this app."))
                .font(.caption)
                .foregroundColor(.secondary)

            if let pin = pairing.pairingPIN {
                Text("PIN: \(pin)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(.blue)
                Text("Type it in Settings › Privacy & Security › Developer Mode › Pair with App")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if pairing.running {
                Text("Pairing… \(pairing.pairingStatus)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    if pairing.running {
                        pairing.softCancel()
                    } else {
                        Task { await runPairing() }
                    }
                } label: {
                    Text(LocalizedStringKey(pairing.running ? "Cancel" : "Start pairing"))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Re-check") { vm.refreshPairingState() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                if LocalDevVPN.isInstalled {
                    Button("Open LocalDevVPN") { LocalDevVPN.open() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }

            HStack(spacing: 10) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import pairing file", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Pairing records are easy to lose — a re-signed build gets a
                // fresh container — so hand the user a way to get a copy out.
                if let url = vm.pairingFileURL {
                    ShareLink(item: url) {
                        Label("Export pairing file", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.pairingTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.adoptPairingFile(at: url) }
            case .failure(let error):
                vm.append("Import failed: \(error.localizedDescription)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func runPairing() async {
        do {
            let path = try await PairingController.shared.startAndWait()
            vm.refreshPairingState()
            vm.append("✅ Paired: \(path)")
        } catch {
            vm.append("✗ Pairing failed: \(error.localizedDescription)")
            vm.refreshPairingState()
        }
    }

    // MARK: tunnel

    private var tunnelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loopback tunnel address")
                .font(.subheadline.weight(.medium))
            TextField("10.7.0.1", text: $vm.deviceIP)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { vm.saveDeviceIP() }
            Text("LocalDevVPN has to be running in loopback mode. 10.7.0.1 by default; try 10.7.0.2 or 10.7.0.3 if it will not connect.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("⚠️ Never enter 127.0.0.1: remotepairingdeviced refuses the control channel and drops into a state where every connection fails, until you toggle Developer Mode off and on again.")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: about

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.subheadline.weight(.medium))
            HStack {
                Text("Version")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(versionDescription)
                    .font(.system(.caption, design: .monospaced))
            }
            Link("GitHub repository",
                 destination: URL(string: "https://github.com/YiHoooong/MetalUHD-iOS")!)
                .font(.caption)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - LocalDevVPN helper

enum LocalDevVPN {
    private static let url = URL(string: "localdevvpn://")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(url)
    }

    static func open() {
        UIApplication.shared.open(url)
    }
}
