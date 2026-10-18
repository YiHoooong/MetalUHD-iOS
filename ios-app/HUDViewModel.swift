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

/// Screen state plus the one place a device run is serialised.
///
/// There is exactly one instance because the device tolerates a single exploit
/// session at a time and because the log sink is shared with the FFI callbacks.
@MainActor
final class HUDViewModel: ObservableObject {

    static let shared = HUDViewModel()

    @Published var log: [String] = []
    @Published var busy = false
    @Published var stage = ""
    @Published var state: HUDState = .unknown
    @Published var outcomeLines: [String] = []
    @Published var lastSummary = ""
    @Published var cfprefsdSees: Bool? = nil
    @Published var writeVerified = false
    @Published var deviceIP = HUDEngine.defaultTargetHost
    @Published var pairingReady = false
    @Published var pairingName = ""
    /// The pairing file on disk, for the share sheet. Nil until one exists.
    @Published var pairingFileURL: URL?

    // Per-app HUD support.
    @Published var apps: [InstalledApp] = []
    @Published var appsLoaded = false
    @Published var selectedBundleID: String? = nil
    @Published var appFilter = ""

    // Diagnostics.
    @Published var lastWriteAt: Date? = HUDViewModel.storedLastWrite
    @Published var lastAppTarget: String = ""
    @Published var reloadProbe: ReloadProbe? = nil

    private var drainTimer: Timer?
    /// The last URL handed to `adoptPairingFile`, so a share-sheet open that is
    /// delivered twice (app delegate + SwiftUI's onOpenURL) only imports once.
    private var lastAdoption: (path: String, at: Date)?
    /// The tail of the run queue.
    private var chain: Task<HUDOutcome, Never>?
    private var queued = 0

    private static let lastWriteKey = "metaluhdLastWrite"

    private static var storedLastWrite: Date? {
        let t = UserDefaults.standard.double(forKey: lastWriteKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private init() {
        deviceIP = HUDEngine.storedTargetHost
        refreshPairingState()
    }

    // MARK: lifecycle

    func refreshPairingState() {
        let path = PairingController.pairingFilePath()
        // A zero-byte pairing file is what a failed pairing leaves behind, so
        // treat it as "not ready" rather than offering it for export.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        pairingReady = size > 0
        pairingFileURL = pairingReady ? URL(fileURLWithPath: path) : nil
        pairingName = AppIdentity.name
    }

    func saveDeviceIP() {
        HUDEngine.storedTargetHost = deviceIP
    }

    var hasBackup: Bool {
        FileManager.default.fileExists(atPath: HUDEngine.backupURL.path)
    }

    var selectedApp: InstalledApp? {
        guard let id = selectedBundleID else { return nil }
        return apps.first { $0.bundleID == id }
    }

    var filteredApps: [InstalledApp] {
        let query = appFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    // MARK: diagnostics

    /// The iOS version and model, for the diagnostics card.
    var deviceDescription: String {
        "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
    }

    /// Whether the device has been rebooted since the last successful write.
    /// cfprefsd only re-reads the preferences files at boot, so this is the
    /// key check after a write.
    var rebootedSinceWrite: Bool? {
        guard let date = lastWriteAt else { return nil }
        let bootTime = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        return bootTime > date.timeIntervalSince1970
    }

    var lastWriteDescription: String {
        guard let date = lastWriteAt else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Runs the cfprefsd external-edit probe. Cheap: it only touches this
    /// app's own preferences file, no device session needed.
    func runReloadProbe() {
        let probe = HUDEngine.probeCfprefsdReload()
        reloadProbe = probe
        append("cfprefsd probe: \(probe.detail)")
    }

    private func recordWrite() {
        let now = Date()
        lastWriteAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastWriteKey)
    }

    // MARK: pairing file

    /// Adopt a pairing file handed to us from outside the app: the document
    /// picker, the share sheet, or another app's "Open in MetalUHD".
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

    // MARK: runs

    /// Runs one global action and waits for its outcome.
    @discardableResult
    func run(_ action: HUDAction) async -> HUDOutcome {
        await enqueue(action.title) { pairingPath in
            HUDEngine.run(action, pairingPath: pairingPath)
        }
    }

    /// Runs one per-app action.
    @discardableResult
    func runForApp(_ app: InstalledApp, enabled: Bool) async -> HUDOutcome {
        let title = "\(enabled ? "Enable" : "Disable") · \(app.name)"
        return await enqueue(title) { pairingPath in
            HUDEngine.applyForApp(app, enabled: enabled, pairingPath: pairingPath)
        }
    }

    @discardableResult
    func checkForApp(_ app: InstalledApp) async -> HUDOutcome {
        await enqueue("Check · \(app.name)") { pairingPath in
            HUDEngine.checkApp(app, pairingPath: pairingPath)
        }
    }

    private func enqueue(_ label: String,
                         _ work: @escaping @Sendable (String) -> HUDOutcome) async -> HUDOutcome {
        let previous = chain
        queued += 1
        busy = true

        let task = Task { @MainActor in
            defer { self.finishQueuedRun() }
            _ = await previous?.value
            return await self.execute(label, work)
        }
        chain = task
        return await task.value
    }

    /// Fire-and-forget wrappers for buttons.
    func request(_ action: HUDAction) {
        Task { await run(action) }
    }

    func requestForApp(_ app: InstalledApp, enabled: Bool) {
        Task { await runForApp(app, enabled: enabled) }
    }

    func requestCheckForApp(_ app: InstalledApp) {
        Task { await checkForApp(app) }
    }

    func check() { request(.check) }
    func enable() { request(.enable) }
    func disable() { request(.disable) }
    func restoreBackup() { request(.restoreBackup) }

    private func finishQueuedRun() {
        queued = max(0, queued - 1)
        if queued == 0 { busy = false }
    }

    private func execute(_ label: String,
                         _ work: @escaping @Sendable (String) -> HUDOutcome) async -> HUDOutcome {
        stage = label
        append("── \(label) ──")

        // Resolved on the main actor before the job: PairingController is
        // @MainActor, so the background work must not call into it.
        HUDEngine.applyTargetHost(deviceIP)
        let pairingPath = PairingController.pairingFilePath()
        startDraining()

        let outcome = await Task.detached(priority: .userInitiated) {
            work(pairingPath)
        }.value

        stopDraining()
        stage = ""
        for line in outcome.lines { append(line) }
        outcomeLines = outcome.lines
        lastSummary = outcome.summary
        state = outcome.state
        cfprefsdSees = outcome.cfprefsdSees
        writeVerified = outcome.writeVerified
        if outcome.ok, outcome.action == .enable || outcome.action == .disable {
            recordWrite()
        }
        if outcome.appPrefsPath != nil {
            lastAppTarget = outcome.target
        }
        return outcome
    }

    // MARK: app list

    /// Loads the installed-app list over InstallationProxy. This is a device
    /// session of its own, so it waits for any queued run to finish.
    func loadApps() {
        guard !busy else { return }
        busy = true
        stage = "Loading installed apps…"
        append("── Loading installed apps ──")

        Task {
            _ = await chain?.value
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
                if selectedBundleID == nil || !list.contains(where: { $0.bundleID == selectedBundleID }) {
                    selectedBundleID = list.first?.bundleID
                }
                append("Found \(list.count) installed app(s)")
            case let .failure(f):
                append("✗ App list failed: \(f.message)")
            }
            stage = ""
            busy = false
        }
    }

    /// Launches the selected app with MTL_HUD_ENABLED=1 through CoreDevice.
    /// This is the cleanest route: no reboot, no defaults edit.
    func launchWithHUD(_ app: InstalledApp) {
        guard !busy else { return }
        busy = true
        stage = "Launching \(app.name)…"
        append("── Launch with HUD: \(app.name) ──")
        let pairingPath = PairingController.pairingFilePath()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HUDEngine.launchWithHUD(app, pairingPath: pairingPath)
            }.value
            switch result {
            case let .success(pid):
                append("✅ Launched \(app.name) with MTL_HUD_ENABLED=1 (pid \(pid))")
                append("No reboot needed. The HUD should appear in the game's top-right corner.")
                lastSummary = "\(app.name): launched with HUD"
                state = .enabled
            case let .failure(f):
                append("✗ Launch with HUD failed: \(f.message)")
                append("If this reports a missing service, this iOS build needs the developer disk image — use the PC/DVT route.")
                lastSummary = "Launch with HUD failed"
            }
            stage = ""
            busy = false
        }
    }

    // MARK: reboot

    /// Ask Diagnostics Relay to restart the device. A reboot is what makes the
    /// edited preferences visible to every process (cfprefsd caches them).
    func reboot() {
        guard !busy else { return }
        busy = true
        stage = "Restarting the device…"
        append("── Reboot device ──")
        let pairingPath = PairingController.pairingFilePath()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HUDEngine.rebootDevice(pairingPath: pairingPath)
            }.value
            switch result {
            case .success:
                append("✅ Restart requested. The device will reboot in a few seconds.")
                append("After it comes back, force-quit and relaunch the target app.")
            case let .failure(f):
                append("✗ Reboot failed: \(f.message)")
                append("You can also reboot from Settings › General › Shut Down.")
            }
            stage = ""
            busy = false
        }
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
