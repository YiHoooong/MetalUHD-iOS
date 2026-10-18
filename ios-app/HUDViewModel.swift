import Foundation
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

/// Screen state plus the one place a run is serialised.
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

    private var drainTimer: Timer?
    /// The last URL handed to `adoptPairingFile`, so a share-sheet open that is
    /// delivered twice (app delegate + SwiftUI's onOpenURL) only imports once.
    private var lastAdoption: (path: String, at: Date)?
    /// The tail of the run queue. A Shortcut and the view's automatic check can
    /// arrive at the same moment.
    private var chain: Task<HUDOutcome, Never>?
    private var queued = 0

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

    /// Runs one action and waits for its outcome.
    @discardableResult
    func run(_ action: HUDAction) async -> HUDOutcome {
        let previous = chain
        queued += 1
        busy = true

        let task = Task { @MainActor in
            defer { self.finishQueuedRun() }
            _ = await previous?.value
            return await self.execute(action)
        }
        chain = task
        return await task.value
    }

    /// Fire-and-forget, for buttons.
    func request(_ action: HUDAction) {
        Task { await run(action) }
    }

    func check() { request(.check) }
    func enable() { request(.enable) }
    func disable() { request(.disable) }
    func restoreBackup() { request(.restoreBackup) }

    private func finishQueuedRun() {
        queued = max(0, queued - 1)
        if queued == 0 { busy = false }
    }

    private func execute(_ action: HUDAction) async -> HUDOutcome {
        stage = action.title
        append("── \(action.title) ──")

        // Resolved on the main actor before the job: PairingController is
        // @MainActor, so the background work must not call into it.
        HUDEngine.applyTargetHost(deviceIP)
        let pairingPath = PairingController.pairingFilePath()
        startDraining()

        let outcome = await Task.detached(priority: .userInitiated) {
            HUDEngine.run(action, pairingPath: pairingPath)
        }.value

        stopDraining()
        stage = ""
        for line in outcome.lines { append(line) }
        outcomeLines = outcome.lines
        lastSummary = outcome.summary
        state = outcome.state
        cfprefsdSees = outcome.cfprefsdSees
        writeVerified = outcome.writeVerified
        return outcome
    }

    // MARK: reboot

    /// Ask Diagnostics Relay to restart the device. A reboot is what makes the
    /// edited global domain visible to every process (cfprefsd caches it).
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
                append("After it comes back, open any Metal app (a game) and look for the HUD in the top-right corner.")
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
