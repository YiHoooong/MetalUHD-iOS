# MetalUHD

[简体中文](README.zh-CN.md)

MetalUHD is an on-device iOS utility that enables Apple's Metal Performance HUD
inside any installed application, including App Store apps. It does not require
a computer, a jailbreak, or a device reboot.

The app reuses the AirTraffic sandbox escape from
[AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) to reach the
device's own services over the LocalDevVPN loopback tunnel, then launches the
selected app through iOS 17+'s CoreDevice app service with
`MTL_HUD_ENABLED=1`.

> **Status:** experimental. Supported on iOS 18.0 through iOS 27.2 beta 2.

---

## How it works

```
LocalDevVPN (loopback mode)
        │
        ▼
RPPairing  →  RSD tunnel (terminates on the device)
        │
        ├── InstallationProxy     list installed applications
        ├── SpringBoardServices   fetch application icons
        └── CoreDevice appservice launch an app with environment variables
```

The launch is equivalent to running

```sh
devicectl device process launch --env MTL_HUD_ENABLED=1 <bundle-id>
```

except that it is performed entirely on the phone. CoreDevice's
`com.apple.coredevice.appservice` accepts an `environmentVariables` dictionary,
which is what makes the HUD switch reach apps that ignore user defaults.

An optional self-test screen renders a small Metal view and enables the HUD for
MetalUHD's own process, so HUD support can be verified independently of any
third-party app.

## Why the preferences route is not used

Apple documents `MetalForceHudEnabled` as an app-domain user default and limits
the HUD on iOS to development-signed and TestFlight applications. On-device
testing matched that:

| Approach | Result |
|---|---|
| `MetalForceHudEnabled` written to `.GlobalPreferences.plist`, device rebooted | `cfprefsd` reports `true`; App Store games show no HUD |
| Keys written to the target app's own `Library/Preferences/<bundle>.plist` | Same: the game ignores them |
| CoreDevice launch with `MTL_HUD_ENABLED=1` | HUD appears immediately, no reboot |

The preferences code path was therefore removed from the application.
`MTL_HUD_ELEMENTS` is also not exposed: this iOS build renders an empty bar for
every named layout the system accepts on macOS.

## Features

- **Application grid.** Four columns with real icons and names. Tapping an icon
  force-quits that app if needed and relaunches it with the HUD enabled.
- **Tunnel check.** LocalDevVPN is probed before any device operation; if it is
  not running, the app offers to open it instead of failing after a long wait.
- **HUD options.** `MTL_HUD_SCALE` and `MTL_HUD_ALIGNMENT` are configurable and
  applied on the next launch.
- **Self-test.** Renders a Metal triangle and enables the HUD for the app's own
  process.
- **Pairing and diagnostics.** RPPairing host, pairing-file import/export,
  loopback address, run log and device information.

## Requirements

- iOS 18.0 – 27.2 beta 2. Apple patched the underlying `airlift` escape in
  iOS 27.2 beta 3; later versions are not supported.
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) running in loopback
  mode. The default gateway is `10.7.0.1`; do not use `127.0.0.1`, which wedges
  `remotepairingdeviced` until Developer Mode is toggled.
- A pairing record. It can be created in the app (the PIN is delivered as a
  notification while you are in Settings) or imported from another sideloading
  tool.
- Apple Books installed and opened at least once, so `com.apple.atc` permits the
  sync.

## Build

Rust core is cross-compiled for iOS, so a macOS host with Xcode 16 or newer is
required for local builds.

**GitHub Actions** (no Mac needed):

1. Push to the repository.
2. Run the **Build unsigned IPA** workflow, or push a change under
   `rust-core/`, `ios-app/`, `project.yml`, the build scripts or the workflow.
3. The IPA is published as a GitHub Release asset, not as a zip artifact.

```sh
gh release download v0.8.5 -R YiHoooong/MetalUHD-iOS -p MetalUHD.ipa -O MetalUHD.ipa
```

**Local build:**

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # build/MetalUHD.ipa
```

The IPA is intentionally unsigned. Sign it with the same tool used for other
sideloaded apps (AltStore, SideStore, Sideloadly, TrollStore, and so on).

> The hard reference to `ALGetGrappaToken` in `MetalUHDApp.swift` must stay.
> The Rust core resolves the symbol with `dlsym`; without a static reference the
> linker may strip it and every sync fails with *"Grappa session could not be
> established"*.

## Usage

1. Start LocalDevVPN in loopback mode.
2. Open MetalUHD. The application list loads once the pairing file is present.
3. Tap the game's icon. If it is already running it is terminated and restarted
   with `MTL_HUD_ENABLED=1`.
4. Adjust scale or alignment under **Settings → HUD**; changes apply on the next
   launch.

No reboot is required.

The HUD is drawn into the application's own drawable, so its sharpness follows
the game's render resolution. Games with dynamic resolution scaling produce a
softer overlay. Scale and alignment are the only supported adjustments; content
layout (`MTL_HUD_ELEMENTS`) is not available on this iOS build.

## Risks and limitations

- Tapping an app kills the running instance, including unsaved progress.
- Some games with anti-cheat may treat a developer-style launch as suspicious.
- The technique depends on the airlift escape and stops working from iOS 27.2
  beta 3 onward.
- CoreDevice's `launchapplication` may require a mounted developer disk image on
  some iOS builds. If the log shows `coredevice appservice published: false` or
  `launchapplication failed`, use the desktop route instead:
  `pymobiledevice3 developer dvt launch --env MTL_HUD_ENABLED=1 <bundle-id>`.

## Repository layout

```
.
├── ios-app/                  SwiftUI application
│   ├── ContentView.swift     tab bar: HUD / Log / Settings
│   ├── HUDHomeView.swift     status card and application grid
│   ├── LogView.swift         diagnostics and run log
│   ├── SettingsView.swift    pairing, HUD options, tunnel, about
│   ├── HUDViewModel.swift    state, app list, icons, launches
│   ├── HUDEngine.swift       InstallationProxy / SpringBoard / CoreDevice
│   ├── MetalHUDTest.swift    in-app Metal HUD self-test
│   ├── PairingController.swift
│   └── Assets.xcassets/      app icon (generated by tools/make-icon.py)
├── rust-core/                Rust FFI compiled to AirliftFFI.xcframework
├── tools/
│   ├── icon-source.png       icon artwork
│   └── make-icon.py          icon pipeline
├── build-ios.sh
├── build-ipa.sh
└── .github/workflows/build-ios.yml
```

## Credits

- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS):
  pairing flow, Rust core and build scripts.
- [airlift](https://github.com/0xjohnnydev/airlift) (Johnny Franks): original
  PoC and ATAirlock analysis.
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) (Mak5er): loopback
  tunnel, Rust FFI core and Grappa tokens.
- [idevice](https://github.com/jkcoxson/idevice): RSD, AFC, CoreDevice and
  InstallationProxy plumbing.
- [MetalHUDHelper](https://github.com/oliwonders/MetalHUDHelper),
  [Nugget](https://github.com/leminlimez/Nugget) and
  [DukeX](https://github.com/MaftyManicEMU/DukeX): references for
  `MetalForceHudEnabled` and its key variants.
- [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher):
  reference for the `MTL_HUD_ENABLED` injection route.

## License

MIT. See [LICENSE](LICENSE). Portions are derived from the projects above and
remain under their original copyright.
