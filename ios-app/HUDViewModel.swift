import Foundation
import UIKit
import SwiftUI
import UserNotifications

// MARK: - App identity

/// The app's single public name: home screen, pairing host, UI headings.
enum AppIdentity {
    static let name = "MetalUHD"
}

// MARK: - Pairing PIN notification

/// The PIN has to be read while the user is inside Settings typing it, and the
/// app's own screen is not visible at that moment — so post it as a
/// notification as well.
enum PinNotifier {
    private static let identifier = "metaluhd-pairing-pin"

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing code  \(pin)"
        content.body = "Type it in Settings › Privacy & Security › Developer Mode › Pair with App"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

// MARK: - View model

/// Screen state: the app list, the selected game, the HUD options and the one
/// device operation the app performs now (launch with `MTL_HUD_ENABLED=1`).
@MainActor
final class HUDViewModel: ObservableObject {

    static let shared = HUDViewModel()

    @Published var log: [String] = []
    @Published var busy = false
    @Published var stage = ""
    @Published var state: HUDState = .unknown
    @Published var lastSummary = ""
    @Published var deviceIP = HUDEngine.defaultTargetHost
    @Published var pairingReady = false
    @Published var pairingName = ""
    /// The pairing file on disk, for the share sheet. Nil until one exists.
    @Published var pairingFileURL: URL?

    // App list.
    @Published var apps: [InstalledApp] = []
    @Published var appsLoaded = false
    @Published var appFilter = ""
    @Published var appIcons: [String: UIImage] = [:]

    // HUD launch options. "default"/"" means "do not override Apple".
    @Published var hudScale: String = UserDefaults.standard.string(forKey: "metaluhdScale") ?? ""
    @Published var hudAlignment: String = UserDefaults.standard.string(forKey: "metaluhdAlignment") ?? "default"

    // Diagnostics.
    @Published var lastLaunchAt: Date? = HUDViewModel.storedLastLaunch

    // LocalDevVPN state.
    @Published var vpnConnected: Bool? = nil
    @Published var showVPNAlert = false

    private var drainTimer: Timer?
    /// The last URL handed to `adoptPairingFile`, so a share-sheet open that is
    /// delivered twice (app delegate + SwiftUI's onOpenURL) only imports once.
    private var lastAdoption: (path: String, at: Date)?

    private static let lastLaunchKey = "metaluhdLastLaunch"

    private static var storedLastLaunch: Date? {
        let t = UserDefaults.standard.double(forKey: lastLaunchKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private init() {
        deviceIP = HUDEngine.storedTargetHost
        refreshPairingState()
    }

    // MARK: lifecycle

    func refreshPairingState() {
        let path = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        pairingReady = size > 0
        pairingFileURL = pairingReady ? URL(fileURLWithPath: path) : nil
        pairingName = AppIdentity.name
    }

    func saveDeviceIP() {
        HUDEngine.storedTargetHost = deviceIP
    }

    private var iconCacheDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metaluhd-icons", isDirectory: true)
    }

    var filteredApps: [InstalledApp] {
        let query = appFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    // MARK: diagnostics

    var deviceDescription: String {
        "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
    }

    var lastLaunchDescription: String {
        guard let date = lastLaunchAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func recordLaunch() {
        let now = Date()
        lastLaunchAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastLaunchKey)
    }

    // MARK: pairing file

    /// Adopt a pairing file handed to us from outside the app.
    @discardableResult
    func adoptPairingFile(at url: URL) -> Bool {
        let now = Date()
        if let last = lastAdoption, last.path == url.path,
           now.timeIntervalSince(last.at) < 2 {
            return pairingReady
        }
        lastAdoption = (url.path, now)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let adopted = PairingController.syncCanonicalPairingFile(from: url.path)
        refreshPairingState()
        if pairingReady {
            append("Imported pairing file: \((adopted as NSString).lastPathComponent)")
        } else {
            append("That file has no readable content, so it is probably not a pairing record: \(url.lastPathComponent)")
        }
        return pairingReady
    }

    // MARK: app list

    /// Loads the installed-app list over InstallationProxy. LocalDevVPN must be
    /// up first; if it is not, show the Open-VPN prompt instead of spinning.
    func loadApps() {
        guard !busy else { return }
        Task {
            guard await ensureVPN() else { return }
            busy = true
            stage = "Loading installed apps…"
            append("── Loading installed apps ──")

            let pairingPath = PairingController.pairingFilePath()
            startDraining()
            let result = await Task.detached(priority: .userInitiated) {
                HUDEngine.listApps(pairingPath: pairingPath)
            }.value
            stopDraining()

            switch result {
            case let .success(list):
                apps = list
                appsLoaded = true
                append("Found \(list.count) installed app(s)")

                stage = "Loading app icons…"
                let dir = iconCacheDir
                let iconResult = await Task.detached(priority: .utility) {
                    HUDEngine.cacheAppIcons(list, pairingPath: pairingPath, outDir: dir)
                }.value

                var icons: [String: UIImage] = [:]
                for app in list {
                    let name = HUDEngine.iconFileName(for: app.bundleID)
                    let url = dir.appendingPathComponent("\(name).png")
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                        icons[app.bundleID] = image
                    }
                }
                appIcons = icons
                if case let .failure(f) = iconResult {
                    append("⚠️ App icons unavailable: \(f.message)")
                } else {
                    append("Loaded \(icons.count) app icon(s)")
                }
            case let .failure(f):
                append("✗ App list failed: \(f.message)")
            }
            stage = ""
            busy = false
        }
    }

    // MARK: launch

    /// Launches the selected app with `MTL_HUD_ENABLED=1` through CoreDevice.
    /// No reboot, no defaults edit.
    func launchWithHUD(_ app: InstalledApp) {
        guard !busy else { return }
        Task {
            guard await ensureVPN() else { return }
            busy = true
            stage = "Launching \(app.name)…"
            append("── Launch with HUD: \(app.name) ──")

            let pairingPath = PairingController.pairingFilePath()
            let rawScale = hudScale.trimmingCharacters(in: .whitespaces)
            let scale = rawScale.isEmpty ? 0.0 : min(max(Double(rawScale) ?? 0.0, 0.1), 1.0)
            let alignment = hudAlignment == "default" ? "" : hudAlignment
            // MTL_HUD_ELEMENTS is not supported by this iOS build; never send it.
            let elements = ""
            UserDefaults.standard.set(hudScale, forKey: "metaluhdScale")
            UserDefaults.standard.set(hudAlignment, forKey: "metaluhdAlignment")

            let result = await Task.detached(priority: .userInitiated) {
                HUDEngine.launchWithHUD(app, pairingPath: pairingPath,
                                        scale: scale,
                                        alignment: alignment,
                                        elements: elements)
            }.value
            switch result {
            case let .success(pid):
                append("✅ Launched \(app.name) with MTL_HUD_ENABLED=1 (pid \(pid))")
                append("No reboot needed. The HUD should appear in the game's top-right corner.")
                lastSummary = "\(app.name): launched with HUD"
                state = .launched
                recordLaunch()
            case let .failure(f):
                append("✗ Launch with HUD failed: \(f.message)")
                append("If this reports a missing service, this iOS build needs the developer disk image — use the PC/DVT route.")
                lastSummary = "Launch with HUD failed"
            }
            stage = ""
            busy = false
        }
    }

    // MARK: LocalDevVPN

    /// Refreshes the VPN indicator (used by the status card and on appear).
    func refreshVPNStatus() {
        let host = deviceIP
        Task {
            vpnConnected = await HUDEngine.isLocalDevVPNRunning(host: host)
        }
    }

    /// Blocks the device action when the loopback tunnel is down and asks the
    /// user to open LocalDevVPN instead of spinning into a generic failure.
    private func ensureVPN() async -> Bool {
        let ok = await HUDEngine.isLocalDevVPNRunning(host: deviceIP)
        vpnConnected = ok
        if !ok {
            showVPNAlert = true
        }
        return ok
    }

    func openVPN() {
        LocalDevVPN.open()
    }

    // MARK: plumbing

    func append(_ line: String) {
        log.append(line)
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    private func startDraining() {
        drainTimer?.invalidate()
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let new = HUDLog.shared.drain()
                if !new.isEmpty { self.log.append(contentsOf: new) }
            }
        }
    }

    private func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
        log.append(contentsOf: HUDLog.shared.drain())
    }
}
