import Foundation
import Network
import AirliftFFI

// MARK: - State

/// What the app last did. There is only one real action now: launch a game
/// with the HUD enabled.
enum HUDState: Sendable, Equatable {
    case unknown
    case launched

    var label: String {
        switch self {
        case .unknown: return String(localized: "Not launched")
        case .launched: return String(localized: "HUD launched")
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .launched: return "speedometer"
        }
    }
}

struct HUDFailure: Error, Sendable {
    let message: String
}

// MARK: - Installed apps

struct InstalledApp: Codable, Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let container: String
    let version: String

    var id: String { bundleID }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case container
        case version
    }
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

/// Talks to the device through the AirTraffic/RSD tunnel:
///   * list installed user apps (InstallationProxy);
///   * launch one of them with `MTL_HUD_ENABLED=1` (CoreDevice appservice).
///
/// Everything blocks and is thread-agnostic — call it off the main thread.
enum HUDEngine {

    /// The HUD switches we set in our own process for the self-test. The
    /// per-app defaults route is intentionally gone: on iOS it only works for
    /// development-signed apps, and CoreDevice launch covers every app.
    static let hudKeys = ["MetalForceHudEnabled", "MetalHUDForceEnabled", "MetalHudEnabled"]

    /// LocalDevVPN's loopback address. Never 127.0.0.1.
    static let defaultTargetHost = "10.7.0.1"
    static let targetHostKey = "metaluhdDeviceIP"

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

    // MARK: - LocalDevVPN probe

    /// True when the loopback tunnel gateway accepts a TCP connection on the
    /// RSD port. LocalDevVPN has to be running in loopback mode for any device
    /// operation to work, so the UI checks this before spinning up a session.
    static func isLocalDevVPNRunning(host: String, port: UInt16 = 49152,
                                     timeout: TimeInterval = 0.8) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: nwPort,
                                          using: .tcp)
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { value in
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case .waiting:
                    // Keep waiting; the timeout below decides.
                    break
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    // MARK: - app list

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

    // MARK: - app icons

    /// File name used for a cached icon; must match the Rust sanitizer.
    static func iconFileName(for bundleID: String) -> String {
        bundleID.map { ch -> String in
            if (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "." || ch == "-" || ch == "_" {
                return String(ch)
            }
            return "_"
        }.joined()
    }

    /// Fetch and cache icons for `apps` into `outDir` (one RSD session).
    static func cacheAppIcons(_ apps: [InstalledApp], pairingPath: String,
                              outDir: URL) -> Result<Int, HUDFailure> {
        guard !apps.isEmpty else { return .success(0) }
        applyStoredTargetHost()

        let ids = apps.map(\.bundleID)
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(HUDFailure(message: "could not encode the bundle id list"))
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var count: UInt32 = 0
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            json.withCString { j in
                outDir.path.withCString { o in
                    al_cache_app_icons(p, j, o, alLogBridge, nil, &count, &outError)
                }
            }
        }
        defer { if let e = outError { al_string_free(e) } }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "icon fetch failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        return .success(Int(count))
    }

    // MARK: - launch with HUD

    /// Launch an installed app with `MTL_HUD_ENABLED=1` through CoreDevice's
    /// `com.apple.coredevice.appservice` (the on-device equivalent of
    /// `devicectl device process launch --env`).
    ///
    /// - Parameters:
    ///   - scale: `MTL_HUD_SCALE`; 0 leaves it at Apple's default (0.2).
    ///   - alignment: `MTL_HUD_ALIGNMENT`; "" leaves it at Apple's default (topright).
    ///   - elements: `MTL_HUD_ELEMENTS`; always "" — this iOS build renders an
    ///     empty bar for every named layout, so the app does not expose it.
    static func launchWithHUD(_ app: InstalledApp, pairingPath: String,
                              scale: Double, alignment: String,
                              elements: String) -> Result<UInt32, HUDFailure> {
        applyStoredTargetHost()
        var pid: UInt32 = 0
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            app.bundleID.withCString { b in
                alignment.withCString { a in
                    elements.withCString { e in
                        al_launch_app_with_hud(p, b, scale, a, e, alLogBridge, nil, &pid, &outError)
                    }
                }
            }
        }
        defer { if let e = outError { al_string_free(e) } }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "launch failed (rc=\(String(describing: rc)))"
            return .failure(HUDFailure(message: message))
        }
        return .success(pid)
    }
}
