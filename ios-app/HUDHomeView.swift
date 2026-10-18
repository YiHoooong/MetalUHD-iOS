import SwiftUI
import UIKit

/// Home screen: a compact status card and a 4-column grid of installed apps.
/// Tapping an icon force-quits that app and relaunches it with the HUD on.
struct HUDHomeView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    appsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(AppIdentity.name)
            .navigationBarTitleDisplayMode(.inline)
            .alert("LocalDevVPN is not running", isPresented: $vm.showVPNAlert) {
                Button("Open LocalDevVPN") { vm.openVPN() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Open LocalDevVPN (loopback mode) first, then try again.")
            }
            .onAppear {
                vm.refreshPairingState()
                vm.refreshVPNStatus()
                if vm.pairingReady && !vm.appsLoaded && !vm.busy {
                    vm.loadApps()
                }
            }
        }
    }

    // MARK: status

    private var statusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: vm.state.symbol)
                .font(.system(size: 44))
                .foregroundColor(vm.state == .launched ? .green : .secondary)
            Text(vm.lastSummary.isEmpty ? vm.state.label : vm.lastSummary)
                .font(.headline)
                .multilineTextAlignment(.center)

            if vm.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(vm.stage)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
            } else {
                vpnPill
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var vpnPill: some View {
        Button {
            if vm.vpnConnected == false { vm.openVPN() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.vpnConnected == true ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey(vm.vpnConnected == true ? "LocalDevVPN connected" : "LocalDevVPN offline"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed apps")
                    .font(.headline)
                Spacer()
                Button {
                    vm.loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.busy || !vm.pairingReady)
            }

            if !vm.pairingReady {
                Text("Pair first (Settings → pairing) so the app list can be loaded.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if vm.busy && !vm.appsLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(vm.stage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if !vm.appsLoaded {
                Text("Tap the refresh button to load the installed apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                TextField("Search apps or bundle id", text: $vm.appFilter)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(vm.filteredApps) { app in
                        Button {
                            vm.launchWithHUD(app)
                        } label: {
                            VStack(spacing: 6) {
                                icon(for: app)
                                    .frame(width: 62, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                Text(app.name)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.busy)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func icon(for app: InstalledApp) -> some View {
        if let image = vm.appIcons[app.bundleID] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.white)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .padding(9)
                .foregroundColor(.secondary)
                .background(Color(.secondarySystemGroupedBackground))
        }
    }
}
