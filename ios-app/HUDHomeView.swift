import SwiftUI
import UIKit

/// The main page: a status line and the installed apps. Tapping an app
/// force-quits it if needed and launches it with `MTL_HUD_ENABLED=1`.
struct HUDHomeView: View {
    @ObservedObject private var vm = HUDViewModel.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    appsCard
                }
                .padding()
            }
            .navigationTitle(AppIdentity.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                vm.refreshPairingState()
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
                .font(.system(size: 52))
                .foregroundColor(vm.state == .launched ? .green : .gray)
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
                Text("Tap an app to launch it with the Metal HUD.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: apps

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundColor(.blue)
                Text("Installed apps")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    vm.loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
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

                VStack(spacing: 2) {
                    ForEach(vm.filteredApps) { app in
                        Button {
                            vm.launchWithHUD(app)
                        } label: {
                            HStack(spacing: 12) {
                                icon(for: app)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 7)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.busy)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
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
                .padding(4)
                .foregroundColor(.secondary)
                .background(Color(.tertiarySystemBackground))
        }
    }
}
