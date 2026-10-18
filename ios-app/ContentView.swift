import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    /// The shared instance, not a fresh one: a Shortcut run and this screen
    /// have to show the same status.
    @ObservedObject private var vm = HUDViewModel.shared
    @ObservedObject private var pairing = PairingController.shared
    @State private var showLog = false
    @State private var showImporter = false
    @State private var showRebootConfirm = false

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

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if !vm.outcomeLines.isEmpty { outcomeCard }
                    actionButtons
                    howToCard
                    rebootCard
                    pairingCard
                    tunnelCard
                    logCard
                }
                .padding()
            }
            .navigationTitle(AppIdentity.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.refreshPairingState() }
            .onOpenURL { url in
                // Documents opened with this app arrive here and, on a cold
                // launch, through AppDelegate.application(_:open:).
                if url.isFileURL { vm.adoptPairingFile(at: url) }
            }
            .alert("Reboot the device?", isPresented: $showRebootConfirm) {
                Button("Reboot", role: .destructive) { vm.reboot() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("cfprefsd caches the global preferences domain, so the edited .GlobalPreferences.plist is only guaranteed to be read after a restart. The device will restart in a few seconds.")
            }
        }
    }

    // MARK: status

    private var statusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: vm.state.symbol)
                .font(.system(size: 52))
                .foregroundColor(stateColor(vm.state))
            Text(vm.lastSummary.isEmpty ? vm.state.label : vm.lastSummary)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if vm.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(vm.stage).foregroundColor(.secondary)
                }
                .font(.subheadline)
            } else {
                Text("Writes Apple's `MetalForceHudEnabled` key into the device's global preferences.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !vm.outcomeLines.isEmpty {
                HStack(spacing: 8) {
                    badge("write \(vm.writeVerified ? "verified" : "unverified")",
                          color: vm.writeVerified ? .green : .orange)
                    badge(cfprefsdBadge, color: cfprefsdColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var cfprefsdBadge: String {
        switch vm.cfprefsdSees {
        case .none: return "cfprefsd: no key"
        case .some(true): return "cfprefsd: true"
        case .some(false): return "cfprefsd: false"
        }
    }

    private var cfprefsdColor: Color {
        switch vm.cfprefsdSees {
        case .none: return .gray
        case .some(true): return .green
        case .some(false): return .gray
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private func stateColor(_ state: HUDState) -> Color {
        switch state {
        case .unknown: return .gray
        case .enabled: return .green
        case .disabled: return .orange
        case .absent: return .gray
        }
    }

    // MARK: outcome

    private var outcomeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last run")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { vm.outcomeLines = [] }
                    .font(.caption)
            }
            ForEach(vm.outcomeLines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                vm.enable()
            } label: {
                Label("Enable Metal HUD", systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button {
                    vm.check()
                } label: {
                    Label("Check", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    vm.disable()
                } label: {
                    Label("Disable", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if vm.hasBackup {
                Button {
                    vm.restoreBackup()
                } label: {
                    Label("Restore prefs backup", systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .disabled(vm.busy || !vm.pairingReady)
        .opacity((vm.busy || !vm.pairingReady) ? 0.5 : 1)
    }

    // MARK: how-to

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to see the HUD")
                .font(.subheadline.weight(.medium))
            Text("1. Enable Metal HUD (this writes the global preference).")
            Text("2. Reboot — cfprefsd only reloads the file on boot.")
            Text("3. Open a Metal app, e.g. a game. The overlay appears in the top-right corner and shows FPS, frame time and GPU time.")
            Text("If it does not appear, run Check: the file can be correct while cfprefsd still serves the old value.")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: reboot

    private var rebootCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply")
                .font(.subheadline.weight(.medium))
            Text("The plist is on disk, but cfprefsd caches the global domain. Restart the device to make every process read the new value.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                showRebootConfirm = true
            } label: {
                Label("Reboot device", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.busy || !vm.pairingReady)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: pairing

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: vm.pairingReady ? "checkmark.seal.fill" : "person.badge.key")
                    .foregroundColor(vm.pairingReady ? .green : .orange)
                Text(vm.pairingReady ? "Pairing file ready" : "Pairing required")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            Text(vm.pairingReady
                 ? "A pairing file was found, so every action is available."
                 : "The exploit needs a pairing file. Pair this iPhone with itself below, or share an existing pairing file into this app.")
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
                    Text(pairing.running ? "Cancel" : "Start pairing")
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

    // MARK: log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showLog.toggle() }
            } label: {
                HStack {
                    Image(systemName: "text.alignleft")
                    Text("Run log")
                    Spacer()
                    Text(showLog ? "Hide" : "Show")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
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
