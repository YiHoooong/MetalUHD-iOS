import SwiftUI
import UIKit

/// The main page: status, per-app switching, the in-app HUD test, the global
/// fallback, diagnostics and the reboot action.
struct HUDHomeView: View {
    @ObservedObject private var vm = HUDViewModel.shared
    @State private var showRebootConfirm = false
    @State private var showHUDTest = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if !vm.outcomeLines.isEmpty { outcomeCard }
                    perAppCard
                    selfTestCard
                    globalCard
                    diagnosticsCard
                    howToCard
                    rebootCard
                }
                .padding()
            }
            .navigationTitle(AppIdentity.name)
            .navigationBarTitleDisplayMode(.inline)
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
            .alert("Reboot the device?", isPresented: $showRebootConfirm) {
                Button("Reboot", role: .destructive) { vm.reboot() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("cfprefsd caches preferences and is not restarted by a respring. A reboot is the only guaranteed way to make it re-read the files.")
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
                Text("Writes Apple's Metal HUD switch into the target app's defaults (or the global domain).")
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

    // MARK: per app

    private var perAppCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                    .foregroundColor(.blue)
                Text("Per-app HUD (recommended)")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            Text("On iOS the HUD switch is read from the launching app's own defaults, so pick the game and write the key into its container. A global preference is not enough for most App Store apps.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    vm.loadApps()
                } label: {
                    Label("Load installed apps", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.busy || !vm.pairingReady)

                if vm.appsLoaded {
                    Text("\(vm.filteredApps.count) / \(vm.apps.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if vm.appsLoaded {
                TextField("Search apps or bundle id", text: $vm.appFilter)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(vm.filteredApps) { app in
                            Button {
                                vm.selectedBundleID = app.bundleID
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Text(app.bundleID)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if vm.selectedBundleID == app.bundleID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                            .background(vm.selectedBundleID == app.bundleID
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear)
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 220)

                if let app = vm.selectedApp {
                    Text(app.prefsPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 10) {
                        Button {
                            vm.requestForApp(app, enabled: true)
                        } label: {
                            Label("Enable for app", systemImage: "speedometer")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            vm.requestCheckForApp(app)
                        } label: {
                            Label("Check", systemImage: "magnifyingglass")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            vm.requestForApp(app, enabled: false)
                        } label: {
                            Label("Off", systemImage: "xmark.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: self test

    private var selfTestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cube.transparent")
                    .foregroundColor(.purple)
                Text("See the HUD in this app")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            Text("Renders a Metal triangle here and enables the HUD for this process with MTL_HUD_ENABLED. If an FPS overlay appears in the corner, the HUD works on this device — then use the per-app action for a game.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                showHUDTest = true
            } label: {
                Label("Open HUD test", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: global (experimental)

    private var globalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.orange)
                Text("Global preference (experimental)")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            Text("Writes MetalForceHudEnabled into .GlobalPreferences.plist. This is the classic tweak route; on iOS it is not reliably read by App Store apps, so treat it as a fallback.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                Button {
                    vm.enable()
                } label: {
                    Label("Enable in global domain", systemImage: "globe.europe.africa")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                HStack(spacing: 12) {
                    Button {
                        vm.check()
                    } label: {
                        Label("Check", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.disable()
                    } label: {
                        Label("Disable", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if vm.hasBackup {
                    Button {
                        vm.restoreBackup()
                    } label: {
                        Label("Restore global prefs backup", systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(vm.busy || !vm.pairingReady)
            .opacity((vm.busy || !vm.pairingReady) ? 0.5 : 1)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: diagnostics

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.subheadline.weight(.medium))
            diagnosticRow("Device", vm.deviceDescription)
            diagnosticRow("Last write", vm.lastWriteDescription)
            diagnosticRow("Rebooted since write",
                          vm.rebootedSinceWrite == nil ? "—" : (vm.rebootedSinceWrite! ? "yes" : "no"))
            diagnosticRow("cfprefsd (global)", cfprefsdBadge)
            diagnosticRow("cfprefsd external edit", reloadProbeText)
            diagnosticRow("Last target", vm.lastAppTarget.isEmpty ? "—" : vm.lastAppTarget)

            Button {
                vm.runReloadProbe()
            } label: {
                Label("Test cfprefsd reload", systemImage: "bolt.horizontal.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Respring (SpringBoard restart) does not restart cfprefsd; only a reboot is guaranteed to clear its cache. If the probe says cfprefsd notices external edits, a force-quit and relaunch may be enough for a target app.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var reloadProbeText: String {
        guard let probe = vm.reloadProbe else { return "—" }
        return probe.externalEditVisible ? String(localized: "visible") : String(localized: "cached")
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

    // MARK: how-to

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to see the HUD in a game")
                .font(.subheadline.weight(.medium))
            Text("1. Tap Load installed apps and pick the game.")
            Text("2. Tap Enable for app (writes the keys into its defaults).")
            Text("3. Force-quit the game, then relaunch it.")
            Text("4. If it still does not appear, reboot the device — cfprefsd may serve a cached copy.")
            Text("Not every app shows the HUD: some games do not render with Metal directly. Try a 3D game known to use Metal (e.g. Wuthering Waves, Call of Duty: Mobile, Bright Memory).")
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
            Text("Preferences are on disk, but cfprefsd caches them. Restart the device so every process reads the new values.")
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
}
