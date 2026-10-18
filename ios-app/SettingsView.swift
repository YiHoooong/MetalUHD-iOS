import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pairing, HUD options, the tunnel and app info, in a native grouped list.
struct SettingsView: View {
    @ObservedObject private var vm = HUDViewModel.shared
    @ObservedObject private var pairing = PairingController.shared
    @State private var showImporter = false
    @State private var showHUDTest = false

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
            List {
                pairingSection
                hudSection
                tunnelSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.refreshPairingState() }
            .sheet(isPresented: $showHUDTest) {
                NavigationView {
                    MetalHUDTestView()
                        .ignoresSafeArea()
                        .navigationTitle("Metal HUD test")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showHUDTest = false }
                            }
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
        }
    }

    /// Every row goes through this so the separator spans the card.
    @ViewBuilder
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().cardWidthListSeparator()
    }

    // MARK: pairing

    private var pairingSection: some View {
        Section {
            row {
                HStack(spacing: 10) {
                    Image(systemName: vm.pairingReady ? "checkmark.seal.fill" : "person.badge.key")
                        .foregroundColor(vm.pairingReady ? .green : .orange)
                    Text(LocalizedStringKey(vm.pairingReady ? "Pairing file ready" : "Pairing required"))
                    Spacer()
                }
            }

            if let pin = pairing.pairingPIN {
                row {
                    LabeledContent("PIN", value: pin)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                }
            } else if pairing.running {
                row { LabeledContent("Pairing…", value: pairing.pairingStatus) }
            }

            row {
                Button {
                    if pairing.running {
                        pairing.softCancel()
                    } else {
                        Task { await runPairing() }
                    }
                } label: {
                    Text(LocalizedStringKey(pairing.running ? "Cancel" : "Start pairing"))
                }
            }

            row { Button("Re-check") { vm.refreshPairingState() } }

            row {
                Button {
                    showImporter = true
                } label: {
                    Label("Import pairing file", systemImage: "square.and.arrow.down")
                }
            }

            if let url = vm.pairingFileURL {
                row {
                    ShareLink(item: url) {
                        Label("Export pairing file", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if LocalDevVPN.isInstalled {
                row {
                    Button {
                        LocalDevVPN.open()
                    } label: {
                        Label("Open LocalDevVPN", systemImage: "network")
                    }
                }
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text(LocalizedStringKey(vm.pairingReady
                 ? "A pairing file was found, so every action is available."
                 : "The exploit needs a pairing file. Pair this iPhone with itself below, or share an existing pairing file into this app."))
        }
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

    // MARK: HUD

    private var hudSection: some View {
        Section {
            row {
                HStack {
                    Text("Scale")
                    Spacer()
                    TextField("0.20", text: $vm.hudScale)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }

            row {
                Picker("Alignment", selection: $vm.hudAlignment) {
                    ForEach(["default", "tr", "tl", "tc", "cl", "c", "cr", "bl", "bc", "br"], id: \.self) { value in
                        Text(LocalizedStringKey(value == "default" ? "System default" : value))
                    }
                }
            }

            row {
                Button {
                    showHUDTest = true
                } label: {
                    Label("Open HUD test", systemImage: "play.rectangle")
                }
            }
        } header: {
            Text("HUD")
        } footer: {
            Text("Scale is a fraction of the game's drawable width (Apple default 0.2, minimum 300 px). The HUD follows the game's render resolution, so it can look soft. Alignment codes: tr/tl/tc/cl/c/cr/bl/bc/br.")
        }
    }

    // MARK: tunnel

    private var tunnelSection: some View {
        Section {
            row {
                HStack {
                    Text("Address")
                    Spacer()
                    TextField("10.7.0.1", text: $vm.deviceIP)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onSubmit { vm.saveDeviceIP() }
                }
            }
        } header: {
            Text("Tunnel")
        } footer: {
            Text(LocalizedStringKey("LocalDevVPN must run in loopback mode. Never enter 127.0.0.1: remotepairingdeviced refuses the control channel and drops into a state where every connection fails until you toggle Developer Mode off and on again."))
        }
    }

    // MARK: about

    private var aboutSection: some View {
        Section {
            row { LabeledContent("Version", value: versionDescription) }
            row {
                Link("GitHub repository",
                     destination: URL(string: "https://github.com/YiHoooong/MetalUHD-iOS")!)
            }
        } header: {
            Text("About")
        }
    }
}
