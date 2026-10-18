import Foundation
import CoreFoundation
import CryptoKit
import AirliftFFI

// MARK: - Actions & state

/// What the demo can do to the device.
enum HUDAction: String, CaseIterable, Sendable {
    case check
    case enable
    case disable
    case restoreBackup

    var title: String {
        switch self {
        case .check: return "Check"
        case .enable: return "Enable Metal HUD"
        case .disable: return "Disable Metal HUD"
        case .restoreBackup: return "Restore prefs backup"
        }
    }
}

/// What the device's global preferences currently say about the HUD.
enum HUDState: Sendable {
    case unknown
    case enabled
    case disabled
    case absent

    var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .enabled: return "Metal HUD enabled"
        case .disabled: return "Metal HUD disabled"
        case .absent: return "HUD key not set"
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
    /// `true` right after a write means the daemon already picked the file up;
    /// otherwise the change needs a reboot to load.
    let cfprefsdSees: Bool?
    let writeVerified: Bool
}

// MARK: - Log sink

/// Thread-safe sink for FFI log lines. Rust calls the log callback from
/// arbitrary threads, so the UI drains this on a timer instead of touching
/// @Published state from the wrong thread.
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
/// It reads the device's global preferences over the airlift escape, edits the
/// `MetalForceHudEnabled` key, writes the whole plist back, and verifies the
/// bytes. Every method blocks and is thread-agnostic — call it off the main
/// thread. `HUDViewModel.run` is the single serialisation point, because the
/// device tolerates one exploit session at a time.
enum HUDEngine {

    /// Where iOS keeps the global preferences domain.
    static let targetDir = "/var/mobile/Library/Preferences"
    static let leaf = ".GlobalPreferences.plist"

    /// Apple's switch for the Metal Performance HUD. Read at process start from
    /// the app's standard user defaults; the global domain is part of that
    /// search list, which is what this demo relies on.
    static let hudKey = "MetalForceHudEnabled"

    /// LocalDevVPN's loopback address. Never 127.0.0.1: that wedges
    /// remotepairingdeviced until Developer Mode is toggled.
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

    /// The unmodified plist as it was before the first write. Restored by the
    /// "Restore prefs backup" action.
    static var backupURL: URL {
        documentsDirectory.appendingPathComponent("GlobalPreferences-backup.plist")
    }

    private static func stagingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metaluhd_\(UUID().uuidString)")
    }

    // MARK: - entry point

    /// Blocking entry point for one action. Call off the main thread.
    static func run(_ action: HUDAction, pairingPath: String) -> HUDOutcome {
        applyStoredTargetHost()
        switch action {
        case .check: return check(pairingPath: pairingPath)
        case .enable: return apply(enabled: true, pairingPath: pairingPath)
        case .disable: return apply(enabled: false, pairingPath: pairingPath)
        case .restoreBackup: return restoreBackup(pairingPath: pairingPath)
        }
    }

    // MARK: - check

    static func check(pairingPath: String) -> HUDOutcome {
        var lines: [String] = []
        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        switch readDevicePrefs(pairingPath: pairingPath, to: staged) {
        case let .failure(f):
            lines.append("✗ Read failed: \(f.message)")
            return HUDOutcome(action: .check, ok: false, state: .unknown, lines: lines,
                              summary: "Read failed", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        case let .success(data):
            lines.append("Read \(data.count.formatted()) bytes from \(targetDir)/\(leaf)")
            switch hudValue(in: data) {
            case let .failure(f):
                lines.append("✗ \(f.message)")
                return HUDOutcome(action: .check, ok: false, state: .unknown, lines: lines,
                                  summary: "Unreadable plist", cfprefsdSees: preferenceVisibleToSystem(),
                                  writeVerified: false)
            case let .success(value):
                let state: HUDState = value == nil ? .absent : (value! ? .enabled : .disabled)
                lines.append("\(hudKey) = \(describe(value))")
                let visible = preferenceVisibleToSystem()
                lines.append(visibleLine(visible))
                return HUDOutcome(action: .check, ok: true, state: state, lines: lines,
                                  summary: state.label, cfprefsdSees: visible, writeVerified: false)
            }
        }
    }

    // MARK: - enable / disable

    static func apply(enabled: Bool, pairingPath: String) -> HUDOutcome {
        let action: HUDAction = enabled ? .enable : .disable
        var lines: [String] = []

        // 1. Read what is on the device right now.
        let staged = stagingURL()
        defer { try? FileManager.default.removeItem(at: staged) }
        let original: Data
        switch readDevicePrefs(pairingPath: pairingPath, to: staged) {
        case let .failure(f):
            lines.append("✗ Read failed: \(f.message)")
            return HUDOutcome(action: action, ok: false, state: .unknown, lines: lines,
                              summary: "Read failed", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        case let .success(data):
            original = data
            lines.append("Read \(data.count.formatted()) bytes from \(targetDir)/\(leaf)")
        }

        // 2. Keep a copy before changing anything. Only the first copy is
        //    kept: re-saving after a change would overwrite the pristine
        //    original with edited data. If the backup cannot be written, stop
        //    here rather than editing the device without a way back.
        if FileManager.default.fileExists(atPath: backupURL.path) {
            lines.append("Backup already kept: \(backupURL.lastPathComponent)")
        } else {
            do {
                try original.write(to: backupURL, options: .atomic)
                lines.append("Backup saved: \(backupURL.lastPathComponent) (\(original.count.formatted()) B)")
            } catch {
                lines.append("✗ Could not save the backup (\(error.localizedDescription)); refusing to modify the device")
                return HUDOutcome(action: action, ok: false, state: .unknown, lines: lines,
                                  summary: "Backup failed", cfprefsdSees: preferenceVisibleToSystem(),
                                  writeVerified: false)
            }
        }

        // 3. Edit the key, keeping every other key untouched.
        let edited: Data
        switch setHUDKey(enabled, in: original) {
        case let .failure(f):
            lines.append("✗ \(f.message)")
            return HUDOutcome(action: action, ok: false, state: .unknown, lines: lines,
                              summary: "Edit failed", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        case let .success(data):
            edited = data
            lines.append("New plist: \(data.count.formatted()) bytes, \(hudKey) = \(enabled)")
        }

        // 4. Write it to /var/mobile/Library/Preferences/.GlobalPreferences.plist.
        switch writeDevicePrefs(edited, pairingPath: pairingPath) {
        case let .failure(f):
            lines.append("✗ Write failed: \(f.message)")
            return HUDOutcome(action: action, ok: false, state: .unknown, lines: lines,
                              summary: "Write failed", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        case .success:
            lines.append("Wrote \(edited.count.formatted()) bytes to the device")
        }

        // 5. Read the file back and compare SHA-256.
        var verified = false
        switch verifyOnDevice(expecting: edited, pairingPath: pairingPath) {
        case let .failure(f):
            lines.append("✗ Verify: \(f.message)")
        case .success:
            verified = true
            lines.append("Verified: device plist matches the staged bytes (SHA-256)")
        }

        // 6. Ask cfprefsd what it currently believes. If the daemon already
        //    answers with the new value, newly launched apps will see it.
        let visible = preferenceVisibleToSystem()
        lines.append(visibleLine(visible))
        let needsReboot = (visible != enabled)
        lines.append(needsReboot
            ? "⏳ Reboot required: cfprefsd still serves the old global domain."
            : "✅ cfprefsd already serves the new value.")

        let summary = needsReboot
            ? (enabled ? "HUD enabled — reboot to apply" : "HUD disabled — reboot to apply")
            : (enabled ? "HUD enabled" : "HUD disabled")

        return HUDOutcome(action: action, ok: verified || visible == enabled,
                          state: enabled ? .enabled : .disabled, lines: lines,
                          summary: summary, cfprefsdSees: visible, writeVerified: verified)
    }

    // MARK: - restore backup

    static func restoreBackup(pairingPath: String) -> HUDOutcome {
        var lines: [String] = []

        guard let data = try? Data(contentsOf: backupURL) else {
            lines.append("✗ No backup at Documents/\(backupURL.lastPathComponent)")
            return HUDOutcome(action: .restoreBackup, ok: false, state: .unknown, lines: lines,
                              summary: "No backup", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        }
        lines.append("Backup: \(data.count.formatted()) bytes")

        switch writeDevicePrefs(data, pairingPath: pairingPath) {
        case let .failure(f):
            lines.append("✗ Write failed: \(f.message)")
            return HUDOutcome(action: .restoreBackup, ok: false, state: .unknown, lines: lines,
                              summary: "Write failed", cfprefsdSees: preferenceVisibleToSystem(),
                              writeVerified: false)
        case .success:
            lines.append("Wrote the backup back to the device")
        }

        var verified = false
        switch verifyOnDevice(expecting: data, pairingPath: pairingPath) {
        case let .failure(f):
            lines.append("✗ Verify: \(f.message)")
        case .success:
            verified = true
            lines.append("Verified: device plist matches the backup (SHA-256)")
        }

        let visible = preferenceVisibleToSystem()
        lines.append(visibleLine(visible))
        lines.append("⏳ Reboot required if the value above is not what you expect.")

        return HUDOutcome(action: .restoreBackup, ok: verified, state: .unknown, lines: lines,
                          summary: "Backup restored — reboot to apply", cfprefsdSees: visible,
                          writeVerified: verified)
    }

    // MARK: - plist editing

    /// Set the boolean key, preserving every other key and value.
    static func setHUDKey(_ enabled: Bool, in data: Data) -> Result<Data, HUDFailure> {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return .failure(HUDFailure(message: "GlobalPreferences is not a valid property list: \(error.localizedDescription)"))
        }
        guard var dict = parsed as? [String: Any] else {
            return .failure(HUDFailure(message: "global preferences root is not a dictionary"))
        }

        dict[hudKey] = NSNumber(value: enabled)

        guard PropertyListSerialization.propertyList(dict, isValidFor: .binary) else {
            return .failure(HUDFailure(message: "edited preferences are not serialisable as a binary plist"))
        }
        do {
            let out = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            return .success(out)
        } catch {
            return .failure(HUDFailure(message: "serialising the edited preferences failed: \(error.localizedDescription)"))
        }
    }

    /// Read the HUD key out of a global preferences plist.
    static func hudValue(in data: Data) -> Result<Bool?, HUDFailure> {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return .failure(HUDFailure(message: "GlobalPreferences is not a valid property list: \(error.localizedDescription)"))
        }
        guard let dict = parsed as? [String: Any] else {
            return .failure(HUDFailure(message: "global preferences root is not a dictionary"))
        }
        guard let raw = dict[hudKey] else { return .success(nil) }
        if let number = raw as? NSNumber { return .success(number.boolValue) }
        if let string = raw as? String { return .success((string as NSString).boolValue) }
        return .failure(HUDFailure(message: "\(hudKey) has unexpected type \(type(of: raw))"))
    }

    // MARK: - cfprefsd view

    /// What cfprefsd answers for the global domain, via the same CFPreferences
    /// lookup Metal performs. `nil` means the key is not present.
    static func preferenceVisibleToSystem() -> Bool? {
        guard let raw = CFPreferencesCopyValue(
            hudKey as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }

        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return (string as NSString).boolValue }
        return nil
    }

    // MARK: - device I/O

    static func readDevicePrefs(pairingPath: String, to url: URL) -> Result<Data, HUDFailure> {
        try? FileManager.default.removeItem(at: url)

        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            targetDir.withCString { d in
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

    static func writeDevicePrefs(_ data: Data, pairingPath: String) -> Result<Void, HUDFailure> {
        let staged = stagingURL()
        do {
            try data.write(to: staged, options: .atomic)
        } catch {
            return .failure(HUDFailure(message: "staging the new plist failed: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            targetDir.withCString { d in
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

    /// Read the file back off the device and compare its SHA-256 with the bytes
    /// we meant to write.
    static func verifyOnDevice(expecting data: Data, pairingPath: String) -> Result<Void, HUDFailure> {
        var size: UInt64 = 0
        var sha: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            targetDir.withCString { d in
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
    /// global domain from disk.
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

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value = value else { return "not set" }
        return value ? "true" : "false"
    }

    private static func visibleLine(_ visible: Bool?) -> String {
        switch visible {
        case .none: return "cfprefsd now: key not present"
        case .some(true): return "cfprefsd now: true"
        case .some(false): return "cfprefsd now: false"
        }
    }
}
