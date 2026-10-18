import Foundation
import CoreFoundation
import CryptoKit
import AirliftFFI

// MARK: - Actions & state

/// Global-domain actions. Per-app actions take an `InstalledApp` and are
/// separate entry points.
enum HUDAction: String, CaseIterable, Sendable {
    case check
    case enable
    case disable
    case restoreBackup

    var title: String {
        switch self {
        case .check: return String(localized: "Check")
        case .enable: return String(localized: "Enable Metal HUD")
        case .disable: return String(localized: "Disable Metal HUD")
        case .restoreBackup: return String(localized: "Restore prefs backup")
        }
    }
}

/// What the device's preferences currently say about the HUD.
enum HUDState: Sendable {
    case unknown
    case enabled
    case disabled
    case absent

    var label: String {
        switch self {
        case .unknown: return String(localized: "Not checked")
        case .enabled: return String(localized: "Metal HUD enabled")
        case .disabled: return String(localized: "Metal HUD disabled")
        case .absent: return String(localized: "HUD key not set")
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .enabled: return "speedometer"
        case .disabled: return "speedometer"
        case .absent: return "minus.circle"
        }
    }
}

struct HUDFailure: Error, Sendable {
    let message: String
}

/// One run's result: enough for the screen and for the log.
struct HUDOutcome: Sendable {
    let action: HUDAction
    let ok: Bool
    let state: HUDState
    let lines: [String]
    let summary: String
    /// What cfprefsd currently answers for the global domain. `nil` = key absent.
    let cfprefsdSees: Bool?
    let writeVerified: Bool
    /// What was touched: "global preferences" or an app name.
    let target: String
    /// The per-app preferences path, when this outcome came from a per-app run.
    let appPrefsPath: String?
}

// MARK: - Installed apps

struct InstalledApp: Codable, Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let container: String
    let version: String

    var id: String { bundleID }

    var prefsDir: String { container + "/Library/Preferences" }
    var prefsLeaf: String { bundleID + ".plist" }
    var prefsPath: String { prefsDir + "/" + prefsLeaf }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case container
        case version
    }
}

/// Result of the cfprefsd external-edit probe.
struct ReloadProbe: Sendable {
    /// True when cfprefsd returned the value written behind its back.
    let externalEditVisible: Bool
    let detail: String
}

// MARK: - Log sink

/// Thread-safe sink for FFI log lines. Rust calls the log callback from
/// arbitrary threads, so the UI drains this on a timer.
final class HUDLog {
    static let shared = HUDLog()
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 800 { lines.removeFirst(lines.count - 800) }
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll()
        return out
    }
}

/// Non-capturing closure so it converts to a C function pointer.
let alLogBridge: ALLogCallback = { _, msg in
    guard let msg = msg else { return }
    HUDLog.shared.append(String(cString: msg))
}

// MARK: - Engine

/// The device-side half of the demo.
///
/// Two ways to switch the HUD on, because iOS does not read the global domain
/// for this key the way macOS does:
///   * **global** — writes `.GlobalPreferences.plist` (the classic tweak route);
///   * **per app** — writes the target app's own `Library/Preferences/<bundle>.plist`,
///     which is Apple's documented "standard user defaults" path on iOS.
///
/// Every method blocks and is thread-agnostic — call it off the main thread.
/// `HUDViewModel` is the single serialisation point.
enum HUDEngine {

    // MARK: - Targets

    /// Where iOS keeps the global preferences domain.
    static let targetDir = "/var/mobile/Library/Preferences"
    static let leaf = ".GlobalPreferences.plist"

    /// Apple's switch for the Metal Performance HUD. Apple documents
    /// `MetalForceHudEnabled` in the app's standard user defaults; macOS tools
    /// use the same key in the global domain. `MetalHUDForceEnabled` and
    /// `MetalHudEnabled` are the variants other projects set alongside it, so
    /// all three are written (they are independent switches; setting all three
    /// only ever enables the HUD).
    static let hudKeys = ["MetalForceHudEnabled", "MetalHUDForceEnabled", "MetalHudEnabled"]
    static let primaryHudKey = "MetalForceHudEnabled"

    /// LocalDevVPN's loopback address. Never 127.0.0.1.
    static let defaultTargetHost = "10.7.0.1"
    static let targetHostKey = "metaluhdDeviceIP"

    // MARK: - loopback tunnel

    static var storedTargetHost: String {
        get { UserDefaults.standard.string(forKey: targetHostKey) ?? defaultTargetHost }
        set { UserDefaults.standard.set(newValue, forKey: targetHostKey) }
    }

    static func applyTargetHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            al_clear_target_hosts()
        } else {
            trimmed.withCString { _ = al_set_target_host($0) }
        }
    }

    static func applyStoredTargetHost() { applyTargetHost(storedTargetHost) }

    // MARK: - local files

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The unmodified global plist as it was before the first write.
    static var backupURL: URL {
        documentsDirectory.appendingPathComponent("GlobalPreferences-backup.plist")
    }

    /// Per-app backup, keyed by bundle id.
    static func appBackupURL(_ app: InstalledApp) -> URL {
        documentsDirectory.appendingPathComponent("prefs-\(app.bundleID).plist")
    }

    private static func stagingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metaluhd_\(UUID().uuidString)")
    }

    // MARK: - entry points

    /// Blocking entry point for one global action. Call off the main thread.
    static func run(_ action: HUDAction, pairingPath: String) -> HUDOutcome {
        applyStoredTargetHost()
        switch action {
        case .check: return checkGlobal(pairingPath: pairingPath)
        case .enable: return applyGlobal(enabled: true, pairingPath: pairingPath)
        case .disable: return applyGlobal(enabled: false, pairingPath: pairingPath)
        case .restoreBackup: return restoreGlobalBackup(pairingPath: pairingPath)
        }
    }

    /// Blocking app listing. Call off the main thread.
    static func listApps(pairingPath: String) -> Result<[InstalledApp], HUDFailure> {
        applyStoredTargetHost()
        var outJSON: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            al_list_apps(p, alLogBridge, nil, &outJSON, &outError)
        }
        defer {
            if let s = outJSON { al_string_free(s) }
            if let e = outError { al_string_free(e) }
        }
        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "app list failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        guard let json = outJSON else {
            return .failure(HUDFailure(message: "the device returned an empty app list"))
        }
        do {
            let apps = try JSONDecoder().decode([InstalledApp].self, from: Data(String(cString: json).utf8))
            return .success(apps)
        } catch {
            return .failure(HUDFailure(message: "could not decode the app list: \(error.localizedDescription)"))
        }
    }

    // MARK: - global domain

    static func checkGlobal(pairingPath: String) -> HUDOutcome {
        var lines: [String] = []
        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        switch readDeviceFile(pairingPath: pairingPath, dir: targetDir, leaf: leaf, to: staged) {
        case let .failure(f):
            lines.append("✗ Read failed: \(f.message)")
            return makeOutcome(.check, ok: false, state: .unknown, lines: lines,
                               summary: "Read failed", visible: preferenceVisibleToSystem(),
                               verified: false, target: "global preferences", appPath: nil)
        case let .success(data):
            lines.append("Read \(data.count.formatted()) bytes from \(targetDir)/\(leaf)")
            switch hudValues(in: data) {
            case let .failure(f):
                lines.append("✗ \(f.message)")
                return makeOutcome(.check, ok: false, state: .unknown, lines: lines,
                                   summary: "Unreadable plist", visible: preferenceVisibleToSystem(),
                                   verified: false, target: "global preferences", appPath: nil)
            case let .success(values):
                for key in hudKeys {
                    lines.append("\(key) = \(describe(values[key]))")
                }
                let state = stateFor(values)
                let visible = preferenceVisibleToSystem()
                lines.append(visibleLine(visible))
                return makeOutcome(.check, ok: true, state: state, lines: lines,
                                   summary: state.label, visible: visible,
                                   verified: false, target: "global preferences", appPath: nil)
            }
        }
    }

    static func applyGlobal(enabled: Bool, pairingPath: String) -> HUDOutcome {
        let action: HUDAction = enabled ? .enable : .disable
        var lines: [String] = []
        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        let original: Data
        switch readDeviceFile(pairingPath: pairingPath, dir: targetDir, leaf: leaf, to: staged) {
        case let .failure(f):
            lines.append("✗ Read failed: \(f.message)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Read failed", visible: preferenceVisibleToSystem(),
                               verified: false, target: "global preferences", appPath: nil)
        case let .success(data):
            original = data
            lines.append("Read \(data.count.formatted()) bytes from \(targetDir)/\(leaf)")
        }

        // Keep the pristine original once; never overwrite it with edited data.
        if FileManager.default.fileExists(atPath: backupURL.path) {
            lines.append("Backup already kept: \(backupURL.lastPathComponent)")
        } else {
            do {
                try original.write(to: backupURL, options: .atomic)
                lines.append("Backup saved: \(backupURL.lastPathComponent) (\(original.count.formatted()) B)")
            } catch {
                lines.append("✗ Could not save the backup (\(error.localizedDescription)); refusing to modify the device")
                return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                                   summary: "Backup failed", visible: preferenceVisibleToSystem(),
                                   verified: false, target: "global preferences", appPath: nil)
            }
        }

        let edited: Data
        switch editKeys(enabled, in: original) {
        case let .failure(f):
            lines.append("✗ \(f.message)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Edit failed", visible: preferenceVisibleToSystem(),
                               verified: false, target: "global preferences", appPath: nil)
        case let .success(data):
            edited = data
            lines.append("New plist: \(data.count.formatted()) bytes, keys = \(hudKeys.joined(separator: ", ")) → \(enabled)")
        }

        switch writeDeviceFile(edited, pairingPath: pairingPath, dir: targetDir, leaf: leaf) {
        case let .failure(f):
            lines.append("✗ Write failed: \(f.message)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Write failed", visible: preferenceVisibleToSystem(),
                               verified: false, target: "global preferences", appPath: nil)
        case .success:
            lines.append("Wrote \(edited.count.formatted()) bytes to the device")
        }

        var verified = false
        switch verifyOnDevice(expecting: edited, pairingPath: pairingPath, dir: targetDir, leaf: leaf) {
        case let .failure(f):
            lines.append("✗ Verify: \(f.message)")
        case .success:
            verified = true
            lines.append("Verified: device plist matches the staged bytes (SHA-256)")
        }

        let visible = preferenceVisibleToSystem()
        lines.append(visibleLine(visible))
        lines.append("⚠️ iOS may ignore the global domain for this key — use the per-app action if the HUD stays hidden.")

        let summary = enabled ? "Global preference written — reboot and test" : "Global preference cleared — reboot"
        return makeOutcome(action, ok: verified || visible == enabled,
                           state: enabled ? .enabled : .disabled, lines: lines,
                           summary: summary, visible: visible,
                           verified: verified, target: "global preferences", appPath: nil)
    }

    static func restoreGlobalBackup(pairingPath: String) -> HUDOutcome {
        var lines: [String] = []
        guard let data = try? Data(contentsOf: backupURL) else {
            lines.append("✗ No backup at Documents/\(backupURL.lastPathComponent)")
            return makeOutcome(.restoreBackup, ok: false, state: .unknown, lines: lines,
                               summary: "No backup", visible: preferenceVisibleToSystem(),
                               verified: false, target: "global preferences", appPath: nil)
        }
        lines.append("Backup: \(data.count.formatted()) bytes")
        return writeAndVerify(data, action: .restoreBackup, pairingPath: pairingPath,
                              dir: targetDir, leaf: leaf, target: "global preferences",
                              appPath: nil, lines: &lines,
                              successSummary: "Backup restored — reboot to apply")
    }

    // MARK: - per app

    static func checkApp(_ app: InstalledApp, pairingPath: String) -> HUDOutcome {
        var lines: [String] = []
        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        switch readDeviceFile(pairingPath: pairingPath, dir: app.prefsDir, leaf: app.prefsLeaf, to: staged) {
        case let .failure(f):
            lines.append("✗ \(app.name): \(f.message)")
            lines.append("A missing preferences file is normal for an app that never wrote a default.")
            return makeOutcome(.check, ok: false, state: .unknown, lines: lines,
                               summary: "No preferences file", visible: nil,
                               verified: false, target: app.name, appPath: app.prefsPath)
        case let .success(data):
            lines.append("Read \(data.count.formatted()) bytes from \(app.prefsPath)")
            switch hudValues(in: data) {
            case let .failure(f):
                lines.append("✗ \(f.message)")
                return makeOutcome(.check, ok: false, state: .unknown, lines: lines,
                                   summary: "Unreadable prefs", visible: nil,
                                   verified: false, target: app.name, appPath: app.prefsPath)
            case let .success(values):
                for key in hudKeys {
                    lines.append("\(key) = \(describe(values[key]))")
                }
                let state = stateFor(values)
                lines.append(cfprefsdViewLine(for: app.bundleID))
                lines.append("The app reads its defaults at launch — reboot first, write, then launch the app.")
                return makeOutcome(.check, ok: true, state: state, lines: lines,
                                   summary: "\(app.name): \(state.label)", visible: nil,
                                   verified: false, target: app.name, appPath: app.prefsPath)
            }
        }
    }

    static func applyForApp(_ app: InstalledApp, enabled: Bool, pairingPath: String) -> HUDOutcome {
        let action: HUDAction = enabled ? .enable : .disable
        var lines: [String] = []
        lines.append("Target app: \(app.name) (\(app.bundleID))")
        lines.append("Preferences: \(app.prefsPath)")

        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        // Read the app's existing defaults when there are any, so other keys
        // (its own settings) survive. A missing file is fine: create one.
        var base: [String: Any] = [:]
        var originalData: Data? = nil
        switch readDeviceFile(pairingPath: pairingPath, dir: app.prefsDir, leaf: app.prefsLeaf, to: staged) {
        case let .success(data):
            originalData = data
            lines.append("Read \(data.count.formatted()) bytes of existing defaults")
            do {
                var format = PropertyListSerialization.PropertyListFormat.binary
                let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                guard let dict = parsed as? [String: Any] else {
                    lines.append("✗ Existing preferences are not a dictionary; refusing to replace them")
                    return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                                       summary: "Unsupported prefs", visible: nil,
                                       verified: false, target: app.name, appPath: app.prefsPath)
                }
                base = dict
            } catch {
                lines.append("✗ Existing preferences are unreadable (\(error.localizedDescription)); refusing to replace them")
                return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                                   summary: "Unreadable prefs", visible: nil,
                                   verified: false, target: app.name, appPath: app.prefsPath)
            }
        case let .failure(f):
            lines.append("No existing preferences file (\(f.message)); creating one")
        }

        for key in hudKeys {
            base[key] = NSNumber(value: enabled)
        }

        guard PropertyListSerialization.propertyList(base, isValidFor: .binary) else {
            lines.append("✗ Edited defaults are not serialisable")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Edit failed", visible: nil,
                               verified: false, target: app.name, appPath: app.prefsPath)
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: base, format: .binary, options: 0)
        } catch {
            lines.append("✗ Serialising defaults failed: \(error.localizedDescription)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Edit failed", visible: nil,
                               verified: false, target: app.name, appPath: app.prefsPath)
        }

        // Back up the app's original defaults once.
        if let original = originalData {
            let backup = appBackupURL(app)
            if FileManager.default.fileExists(atPath: backup.path) {
                lines.append("Backup already kept: \(backup.lastPathComponent)")
            } else {
                do {
                    try original.write(to: backup, options: .atomic)
                    lines.append("Backup saved: \(backup.lastPathComponent) (\(original.count.formatted()) B)")
                } catch {
                    lines.append("⚠️ Could not save the app prefs backup: \(error.localizedDescription)")
                }
            }
        }

        switch writeDeviceFile(data, pairingPath: pairingPath, dir: app.prefsDir, leaf: app.prefsLeaf) {
        case let .failure(f):
            lines.append("✗ Write failed: \(f.message)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Write failed", visible: nil,
                               verified: false, target: app.name, appPath: app.prefsPath)
        case .success:
            lines.append("Wrote \(data.count.formatted()) bytes to the device")
        }

        var verified = false
        switch verifyOnDevice(expecting: data, pairingPath: pairingPath,
                              dir: app.prefsDir, leaf: app.prefsLeaf) {
        case let .failure(f):
            lines.append("✗ Verify: \(f.message)")
        case .success:
            verified = true
            lines.append("Verified: device file matches the staged bytes (SHA-256)")
        }

        lines.append(cfprefsdViewLine(for: app.bundleID))
        lines.append("⏳ Recommended order: reboot first, then write, then launch \(app.name) — so its defaults are not cached before the write.")
        let summary = "\(app.name): HUD \(enabled ? "enabled" : "disabled") — reboot then relaunch"
        return makeOutcome(action, ok: verified, state: enabled ? .enabled : .disabled, lines: lines,
                           summary: summary, visible: nil, verified: verified,
                           target: app.name, appPath: app.prefsPath)
    }

    // MARK: - shared write path

    private static func writeAndVerify(_ data: Data, action: HUDAction, pairingPath: String,
                                       dir: String, leaf: String, target: String,
                                       appPath: String?, lines: inout [String],
                                       successSummary: String) -> HUDOutcome {
        switch writeDeviceFile(data, pairingPath: pairingPath, dir: dir, leaf: leaf) {
        case let .failure(f):
            lines.append("✗ Write failed: \(f.message)")
            return makeOutcome(action, ok: false, state: .unknown, lines: lines,
                               summary: "Write failed", visible: preferenceVisibleToSystem(),
                               verified: false, target: target, appPath: appPath)
        case .success:
            lines.append("Wrote \(data.count.formatted()) bytes to the device")
        }
        var verified = false
        switch verifyOnDevice(expecting: data, pairingPath: pairingPath, dir: dir, leaf: leaf) {
        case let .failure(f):
            lines.append("✗ Verify: \(f.message)")
        case .success:
            verified = true
            lines.append("Verified: device file matches the staged bytes (SHA-256)")
        }
        return makeOutcome(action, ok: verified, state: .unknown, lines: lines,
                           summary: successSummary, visible: preferenceVisibleToSystem(),
                           verified: verified, target: target, appPath: appPath)
    }

    // MARK: - plist editing

    /// Set the HUD keys, preserving every other key and value.
    static func editKeys(_ enabled: Bool, in data: Data) -> Result<Data, HUDFailure> {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return .failure(HUDFailure(message: "not a valid property list: \(error.localizedDescription)"))
        }
        guard var dict = parsed as? [String: Any] else {
            return .failure(HUDFailure(message: "preferences root is not a dictionary"))
        }
        for key in hudKeys {
            dict[key] = NSNumber(value: enabled)
        }
        guard PropertyListSerialization.propertyList(dict, isValidFor: .binary) else {
            return .failure(HUDFailure(message: "edited preferences are not serialisable as a binary plist"))
        }
        do {
            return .success(try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0))
        } catch {
            return .failure(HUDFailure(message: "serialising the edited preferences failed: \(error.localizedDescription)"))
        }
    }

    /// Read the HUD keys out of a preferences plist (missing keys are absent).
    static func hudValues(in data: Data) -> Result<[String: Bool], HUDFailure> {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return .failure(HUDFailure(message: "not a valid property list: \(error.localizedDescription)"))
        }
        guard let dict = parsed as? [String: Any] else {
            return .failure(HUDFailure(message: "preferences root is not a dictionary"))
        }
        var values: [String: Bool] = [:]
        for key in hudKeys {
            guard let raw = dict[key] else { continue }
            if let number = raw as? NSNumber {
                values[key] = number.boolValue
            } else if let string = raw as? String {
                values[key] = (string as NSString).boolValue
            } else {
                return .failure(HUDFailure(message: "\(key) has unexpected type \(type(of: raw))"))
            }
        }
        return .success(values)
    }

    static func stateFor(_ values: [String: Bool]) -> HUDState {
        if values.isEmpty { return .absent }
        if values.values.contains(true) { return .enabled }
        return .disabled
    }

    // MARK: - cfprefsd view

    /// What cfprefsd answers for the global domain, via the same CFPreferences
    /// lookup Metal performs. `nil` means the key is not present.
    static func preferenceVisibleToSystem() -> Bool? {
        guard let raw = CFPreferencesCopyValue(
            primaryHudKey as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }

        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return (string as NSString).boolValue }
        return nil
    }

    /// Writes directly to this app's own preferences file (bypassing
    /// cfprefsd), then asks cfprefsd for the value again.
    ///
    /// If the value comes back, cfprefsd notices external edits and a target
    /// app that is force-quit and relaunched can pick up a written preference
    /// **without a reboot**. If it does not, a reboot (not a respring) is the
    /// only guaranteed way to clear the cache.
    static func probeCfprefsdReload() -> ReloadProbe {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.yihoooong.metaluhd"
        let key = "MetalUHDCacheProbe"
        let value = UUID().uuidString
        let fileManager = FileManager.default
        let prefsDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        let fileURL = prefsDir.appendingPathComponent("\(bundleID).plist")

        // Flush our own pending defaults, then seed cfprefsd's cache so the
        // second read cannot succeed just because the domain was never loaded.
        UserDefaults.standard.synchronize()
        _ = CFPreferencesCopyValue(key as CFString, bundleID as CFString,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let existing = parsed as? [String: Any] {
            dict = existing
        }
        dict[key] = value

        guard let edited = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                               format: .binary, options: 0) else {
            return ReloadProbe(externalEditVisible: false, detail: "could not serialise the probe")
        }
        do {
            try fileManager.createDirectory(at: prefsDir, withIntermediateDirectories: true)
            try edited.write(to: fileURL, options: .atomic)
        } catch {
            return ReloadProbe(externalEditVisible: false,
                               detail: "could not write the probe: \(error.localizedDescription)")
        }

        let seen = CFPreferencesCopyValue(key as CFString, bundleID as CFString,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        let visible = seen == value

        // Leave our own defaults as they were.
        dict.removeValue(forKey: key)
        if let clean = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                           format: .binary, options: 0) {
            try? clean.write(to: fileURL, options: .atomic)
        }

        return ReloadProbe(
            externalEditVisible: visible,
            detail: visible
                ? "cfprefsd noticed the external edit"
                : "cfprefsd served a cached value"
        )
    }

    /// cfprefsd's own answer for another app's domain (`nil` when the sandbox
    /// refuses the lookup). Used only for diagnostics: a value here means the
    /// daemon is serving the written file, not just the bytes on disk.
    static func preferenceVisible(for bundleID: String) -> Bool? {
        guard let raw = CFPreferencesCopyValue(
            primaryHudKey as CFString,
            bundleID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }

        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return (string as NSString).boolValue }
        return nil
    }

    // MARK: - device I/O

    static func readDeviceFile(pairingPath: String, dir: String, leaf: String,
                               to url: URL) -> Result<Data, HUDFailure> {
        try? FileManager.default.removeItem(at: url)

        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            dir.withCString { d in
                leaf.withCString { l in
                    url.path.withCString { o in
                        al_exploit_read_file_to_path(p, d, l, o, alLogBridge, nil, &outError)
                    }
                }
            }
        }
        defer { if let e = outError { al_string_free(e) } }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "read failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(HUDFailure(message: "Rust reported success but \(url.lastPathComponent) is unreadable"))
        }
        return .success(data)
    }

    static func writeDeviceFile(_ data: Data, pairingPath: String,
                                dir: String, leaf: String) -> Result<Void, HUDFailure> {
        let staged = stagingURL()
        do {
            try data.write(to: staged, options: .atomic)
        } catch {
            return .failure(HUDFailure(message: "staging the new plist failed: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            dir.withCString { d in
                leaf.withCString { l in
                    staged.path.withCString { s in
                        al_exploit_write_file(p, d, l, s, alLogBridge, nil, &outError)
                    }
                }
            }
        }
        defer { if let e = outError { al_string_free(e) } }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "write failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        return .success(())
    }

    static func verifyOnDevice(expecting data: Data, pairingPath: String,
                               dir: String, leaf: String) -> Result<Void, HUDFailure> {
        var size: UInt64 = 0
        var sha: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            dir.withCString { d in
                leaf.withCString { l in
                    al_exploit_read_file_hash(p, d, l, alLogBridge, nil, &size, &sha, &outError)
                }
            }
        }
        defer {
            if let s = sha { al_string_free(s) }
            if let e = outError { al_string_free(e) }
        }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "read-back failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        let expected = sha256Hex(data)
        let actual = sha.map { String(cString: $0) } ?? ""
        guard actual == expected else {
            return .failure(HUDFailure(message: "device bytes differ (device \(actual.prefix(12))…, expected \(expected.prefix(12))…, \(size) B)"))
        }
        return .success(())
    }

    /// Ask Diagnostics Relay to restart the device so cfprefsd reloads the
    /// preferences files from disk.
    static func rebootDevice(pairingPath: String) -> Result<Void, HUDFailure> {
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            al_device_respring(p, alLogBridge, nil, &outError)
        }
        defer { if let e = outError { al_string_free(e) } }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "restart failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        return .success(())
    }

    // MARK: - helpers

    private static func makeOutcome(_ action: HUDAction, ok: Bool, state: HUDState,
                                    lines: [String], summary: String, visible: Bool?,
                                    verified: Bool, target: String,
                                    appPath: String?) -> HUDOutcome {
        HUDOutcome(action: action, ok: ok, state: state, lines: lines, summary: summary,
                   cfprefsdSees: visible, writeVerified: verified, target: target,
                   appPrefsPath: appPath)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value = value else { return "not set" }
        return value ? "true" : "false"
    }

    private static func cfprefsdViewLine(for bundleID: String) -> String {
        switch preferenceVisible(for: bundleID) {
        case .none: return "cfprefsd view (\(bundleID)): unavailable (sandbox may block reading another app's domain)"
        case .some(true): return "cfprefsd view (\(bundleID)): true"
        case .some(false): return "cfprefsd view (\(bundleID)): false"
        }
    }

    private static func visibleLine(_ visible: Bool?) -> String {
        switch visible {
        case .none: return "cfprefsd now: key not present"
        case .some(true): return "cfprefsd now: true"
        case .some(false): return "cfprefsd now: false"
        }
    }
}
