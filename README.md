# MetalUHD (iOS demo)

在 iPhone **本机**打开 Apple 官方的 **Metal Performance HUD**（FPS / 帧时间 / GPU 时间叠加层），
不需要 Mac、不需要 Xcode、不需要越狱。

实现方式：复用 [AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) 所在的
AirTraffic 沙箱逃逸（来自 [airlift](https://github.com/0xjohnnydev/airlift) / [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)），
通过 LocalDevVPN 回环隧道读写设备上的

```
/var/mobile/Library/Preferences/.GlobalPreferences.plist
```

把 **`MetalForceHudEnabled`** 写成 **`true`**（Boolean），保留文件里所有其它键，然后重启设备让系统重新加载。

> [!WARNING]
> 这是一个 **demo**，且当前仓库**尚未在真机上验证过**（开发环境没有设备）。它会在真机上
> **读出并整体重写** `.GlobalPreferences.plist`。App 会先把原文件备份到自己的 Documents，
> 但请自行评估风险后再在主力机上操作。下面的"风险与回滚"一节写清楚了最坏情况。

---

## 它到底改了什么，为什么需要重启

Apple 在 [Discover Metal Performance HUD](https://developer.apple.com/videos/play/tech-talks/110339/)
里说明：在 iOS 上把 **`MetalForceHudEnabled`** 设为 true 后，HUD 会在**后续启动**的 App 里显示；
macOS 上还可以对这个键设全局值。iOS 的 `NSUserDefaults` 标准搜索链包含 global 域，所以本 demo
把值写进 global 域，期望对所有 App 生效。

但 `.GlobalPreferences.plist` 由 **cfprefsd**（用户级偏好守护进程）缓存。我们通过逃逸直接改文件，
绕过了 cfprefsd；**守护进程不会主动重新读这个文件**，所以：

```
写入成功 ≠ 立即生效
```

App 在写完以后会用 `CFPreferencesCopyValue(...)` 直接问 cfprefsd 当前的值：

- 如果它已经返回 `true`，说明守护进程已经拾取了改动，直接打开游戏即可；
- 如果仍返回旧值/无值，就**需要重启**。界面会明确显示这两种情况。

重启后 cfprefsd 从磁盘重新加载，所有新启动的 App 都能读到 `MetalForceHudEnabled = true`。

---

## 实现拆解

```
MetalUHD-iOS/
├── ios-app/                      SwiftUI App（~1100 行）
│   ├── MetalUHDApp.swift         App 入口 / AppDelegate / ALGetGrappaToken 硬引用
│   ├── ContentView.swift         界面
│   ├── HUDViewModel.swift        状态机、串行队列、日志
│   ├── HUDEngine.swift           读 → 备份 → 改 plist → 写 → SHA-256 回读校验 → cfprefsd 探测
│   ├── PairingController.swift   本机 RPPairing 主机（Bonjour + PIN 通知）
│   ├── Utilities.swift           配对期间保活、局域网权限探测
│   └── GrappaHelper.[hm]         Grappa token（逃逸的 atc 认证需要）
├── rust-core/                    Rust FFI（airlift_ffi → AirliftFFI.xcframework）
│   └── src/exploit.rs            AirTraffic 逃逸管线 + 新增的两个 FFI
├── build-ios.sh                  Rust → xcframework
├── build-ipa.sh                  xcodebuild → 未签名 IPA
└── .github/workflows/build-ios.yml   CI 出 IPA
```

### 新增的两个 Rust FFI

原项目的 `al_exploit_write_dir()` 会**跳过以 `.` 开头的文件**（见 `exploit_write_dir` 里的
`filename.starts_with('.')`），而目标恰好是隐藏文件 `.GlobalPreferences.plist`，所以直接复用
写目录的路径行不通。本 demo 补了两个函数：

| 函数 | 作用 |
|---|---|
| `al_exploit_read_file_to_path(pairing, dir, leaf, out_path, …)` | 把设备文件读成原始字节存到 App 沙箱。底层仍是"搬出 → AFC 读 → 写回"三步，但**只要读到了字节就一定写回**（失败重试 3 次；真读不出来时把文件留在 Media 里并报告位置，绝不删除） |
| `al_exploit_write_file(pairing, dir, leaf, local_path, …)` | 按**精确文件名**写单个文件，点文件不跳过；内部复用经过验证的 `exploit_write_single_file` 管线，失败重试 3 次 |

`read_file_hash`（回读校验）沿用原项目。

### 为什么读之前要备份、写完要回读

1. **备份** —— 读出来的原始字节先写进 `Documents/GlobalPreferences-backup.plist`，之后才改。
   界面上的 **Restore prefs backup** 会把它写回去。
2. **回读校验** —— 写完后调用 `al_exploit_read_file_hash` 把设备上的文件重新读出并比 SHA-256。
   `write` 返回 0 只代表协议成功，回读才算落盘。
3. **cfprefsd 探测** —— 见上一节，决定要不要重启。

---

## 前置条件

与 AirliftSilence 相同：

- **iOS 18.0 – 27.2 beta 2**。Apple 在 **iOS 27.2 beta 3 修掉了底层 `airlift` 逃逸**，不要升过 beta 2。
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) 运行在**回环模式**（App 默认拨 `10.7.0.1`）。
  **不要填 `127.0.0.1`** —— 在 iOS 上会让 `remotepairingdeviced` 进入丢弃状态，只能关掉再打开开发者模式恢复。
- 一份**配对记录**：App 内 **Start pairing** 生成（PIN 会以通知形式发出），或导入现成的
  `airlift_pairing.plist` / `.mobiledevicepairing` / `.mobilepairing`。
- 官方「图书」App 装过并至少打开一次（`com.apple.atc` 同步需要）。

---

## 构建

Rust core 要交叉编译到 iOS，所以构建需要 **macOS + Xcode 16+**。没有 Mac 就让 GitHub 构建：

1. 把仓库推到 GitHub；
2. Actions → **Build unsigned IPA** → Run workflow；
3. 下载 `MetalUHD-unsigned-ipa` 构件。

Mac 上：

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # -> build/MetalUHD.ipa（未签名）
```

IPA 是刻意**不签名**的，用你平时签 AirliftSilence 的工具（AltStore / SideStore / Sideloadly / TrollStore…）签。

> [!IMPORTANT]
> `MetalUHDApp.swift` 里对 `ALGetGrappaToken` 的硬引用别删。Rust 那边是用 `dlsym` 找这个符号的，
> 没有硬引用链接器可能把它丢掉，之后每次同步都会以 *"Grappa session could not be established"* 失败。

---

## 使用

1. 打开 LocalDevVPN（回环模式），确认 App 里 **Pairing file ready**；没有就 Start pairing 或导入。
2. 点 **Enable Metal HUD**。一次运行要几十秒（读一次 + 写一次 + 回读校验），日志会实时滚动。
3. 看结果：
   - `write verified` —— 设备上的 plist 与预期字节的 SHA-256 一致；
   - `cfprefsd: true` —— 已生效，**打开游戏**即可（也可先 Check 确认）；
   - `cfprefsd: false / no key` —— 点 **Reboot device**（或手动重启）。
4. 重启后打开任意使用 Metal 的游戏/App，右上角应出现 HUD。

想关掉：点 **Disable Metal HUD**，同样需要重启；想完全恢复原文件：**Restore prefs backup**。

---

## 风险与回滚

- 本 demo 会**整体重写** `.GlobalPreferences.plist`。所有键都从原文件读出、原样写回，只改一个键；
  但"读 → 写"之间如果有进程大量写偏好，理论上存在竞态。**请先用 Disable/恢复流程在一台可恢复的设备上测试。**
- 原文件在第一次写入前会备份到 App 的 Documents（文件共享已开启，可在「文件」App 里拷出来）。
- 万一设备偏好被写坏：重启后 iOS 会用默认值重建 global 域，**不会变砖**，但语言/键盘等个性化设置可能丢失。
  用 **Restore prefs backup** 或把备份拷回 `Documents/metaluhd_pairing.plist` 旁边的
  `GlobalPreferences-backup.plist` 再点恢复即可。
- 传输中断/隧道掉线时，App 会报告失败；此时**不要反复重试**，先 Check 或重启确认设备状态。

---

## 排查

| 现象 | 处理 |
|---|---|
| `Stage verification failed` / 连不上 | LocalDevVPN 是否在跑、地址是否 `10.7.x.x`；换 `10.7.0.2` / `10.7.0.3` |
| `Grappa session could not be established` | 确认 `ALGetGrappaToken` 硬引用还在（见上） |
| 写入成功、重启后仍无 HUD | 先 Check 确认 `MetalForceHudEnabled = true`；再换一个**确实在用 Metal**的游戏；Apple 文档里说 iOS 上 HUD 只对开发签名/TestFlight 的 App 生效，但社区实测 `MTL_HUD_ENABLED` 注入对 App Store App 也有效（见 [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher)），因此这一条可能不影响本方案 —— 需要真机确认 |
| HUD 不显示但想要确定性方案 | 用电脑走 Developer Disk Image，以 `MTL_HUD_ENABLED=1` 环境变量启动 App（`pymobiledevice3 developer dvt launch --env MTL_HUD_ENABLED=1`），这是社区已验证的路线，但每次启动都要电脑 |
| 想确认 key 是否真的在文件里 | 点 **Check**，界面会显示 `MetalForceHudEnabled = true/false/not set` 和 cfprefsd 视角 |

---

## 已知限制

- 依赖 AirTraffic 逃逸，**iOS 27.2 beta 3 起失效**。
- 生效需要**重启**（cfprefsd 缓存）；没有找到在设备上无重启刷新 global 域的办法。
- 只改 global 域里的这一个键；系统卷上的东西、以及需要 root 的偏好域都碰不到。
- 本仓库的 `rust-core/vendor/` 是上游 vendored 依赖，体积较大且包含大量与本 demo 无关的 FFI（`passthm`、zip 解包、respring、syslog 等），保留是为了少改动；后续可以裁剪。

---

## 致谢

- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS) —— 本 demo 直接复用其配对流程、Rust core 与构建脚本
- [airlift](https://github.com/0xjohnnydev/airlift) —— Johnny Franks：原始 PoC 与 ATAirlock 分析
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) —— Mak5er：回环隧道、Rust FFI core、Grappa token
- [idevice](https://github.com/jkcoxson/idevice) —— RSD/AFC/streaming_zip_conduit 管线
- [MetalHUDHelper](https://github.com/oliwonders/MetalHUDHelper) / [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher) —— `MetalForceHudEnabled` 语义与备选路线的参考

MIT，见 [LICENSE](LICENSE)（继承上游，版权归原作者）。
