# MetalUHD (iOS)

在 iPhone **本机**开关 Apple 官方的 **Metal Performance HUD**（FPS / 帧时间 / GPU 时间的叠加层），
不需要 Mac、不需要 Xcode、不需要越狱。界面跟随系统语言（English / 简体中文）。

复用 [AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) 的 AirTraffic 沙箱逃逸
（来自 [airlift](https://github.com/0xjohnnydev/airlift) / [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)），
通过 LocalDevVPN 回环隧道读写设备上的偏好文件。

> [!WARNING]
> 这是一个 **demo**。它会通过逃逸改写设备上的 plist：
> **按 App 写入**时改目标 App 的 `Library/Preferences/<bundle-id>.plist`，
> **全局模式**时整体重写 `.GlobalPreferences.plist`。
> 两种模式都会在首次写入前把原文件备份到 App 的 Documents，但请先在可恢复的设备上测试。

---

## 为什么"写全局域"不显示，而"按 App 写"才是主路径

Apple 在 [Discover Metal Performance HUD](https://developer.apple.com/videos/play/tech-talks/110339/)
里说明：在 iOS 上把 **`MetalForceHudEnabled`** 设为 true（写在 **App 自己的 standard user defaults** 里）
后，HUD 会在**后续启动**的 App 中显示；"global 值"是 macOS 的说法。

实测结果与之一致：把 `MetalForceHudEnabled` 写进 `.GlobalPreferences.plist` 并重启后，
App 里 `Check` 显示 `MetalForceHudEnabled = true`、`cfprefsd: true`，但 App Store 游戏仍然没有 HUD；
所以本 demo 把 **按 App 写入 App 自己的 defaults** 作为主路径，全局域仅作为实验性备选。

另外，Metal HUD 只在**用 Metal 渲染**的 App 里出现。部分游戏（OpenGL / 自绘路径）不会显示，
这不是开关没生效。

### 三个键

不同项目用的键名不完全一致，本 demo 会同时写入：

```
MetalForceHudEnabled    # Apple 文档里的键
MetalHUDForceEnabled    # 其他项目（如 DukeX）同时设置的变体
MetalHudEnabled         # 同上
```

它们都是"HUD 开关"，同时为 true 只会让 HUD 打开。

---

## 一定要重启吗？注销行不行？

- **注销（respring，即重启 SpringBoard）不会重启 cfprefsd。** cfprefsd 是独立守护进程，
  随系统启动而不是随 SpringBoard；它才是缓存偏好的那一方，所以注销理论上清不掉缓存。
- 但 cfprefsd **可能自己会感知外部文件修改**（通过文件变化）。如果会，那么写完偏好后
  **强制退出目标 App 再打开**就够了，连注销都不需要。
- 所以本 App 的「诊断」页有一个 **测试 cfprefsd 重载**：它绕过 cfprefsd 直接改本 App 自己的
  plist，再读回来——
  - 显示 **能感知**：说明外部修改会被拾取，优先试"强退目标 App 再打开"；
  - 显示 **有缓存**：说明必须重启设备（注销也不够）。
- App 里的 **重启设备** 走 Diagnostics Relay，是真正的重启；**没有**注销按钮——
  注销需要越狱/TrollStore 工具去 `killall SpringBoard`，本 App 的权限做不到。

---

## HUD 为什么看起来发虚？

Apple 的 [MetalPerformanceHUD 手册](https://keith.github.io/xcode-man-pages/MetalPerformanceHUD.1.html) 写明：
HUD 是**绘制在 App 自己的 drawable 里**的，`MTL_HUD_SCALE` 是「drawable 宽度的比例」（0.1–1.0，默认 0.2，且小于 300px 时按 300px 画）。
所以：

- 王者荣耀这类游戏会开**动态分辨率/渲染缩放**，HUD 跟着整帧一起被放大 → 看起来糊；
- **没有**"提高 HUD 分辨率"的开关，这是 Apple 的 HUD 设计；
- 能改善的只有：把 `MTL_HUD_SCALE` 调大（0.3–0.5 更好读）、把游戏自己的画面分辨率/画质调高、
  用 `MTL_HUD_ALIGNMENT` 挪到更显眼的位置、用 `MTL_HUD_ELEMENTS` 换更完整的布局。

「设置」页的 **HUD 选项** 就是干这个的，改完重新点「启动并显示 HUD」生效。
默认是**不覆盖** Apple 的默认值（0.2 / 右上 / Lite）——强行覆盖缩放/布局时，
有些游戏在启动阶段旋转或切换 drawable 尺寸，会把 HUD 压成一条横线。

**HUD 变成一条横线怎么办**：把缩放清空、位置/布局留在「系统默认」，重新「启动并显示 HUD」。
如果还不行，先让游戏进到横屏主界面再重启一次（HUD 的尺寸是跟着游戏 drawable 走的）。

---

## 功能

| 功能 | 说明 |
|---|---|
| **HUD 自检** | App 内用 Metal 画一个旋转三角形，并用 `MTL_HUD_ENABLED=1` 给**本进程**打开 HUD。右上角出现 FPS 叠加层 = 这台设备的 HUD 本身可用 |
| **启动并显示 HUD（免重启）** | 通过 CoreDevice 的 `com.apple.coredevice.appservice`，用 `MTL_HUD_ENABLED=1` 直接启动目标 App（等价于 `devicectl process launch --env`），不重启、不改 defaults。**iOS 上优先试这个** |
| **按 App 开启** | 列出已安装 App → 选中游戏 → 把三个键写进它的 `Library/Preferences/<bundle-id>.plist`（保留该 App 原有 defaults） |
| **全局域（实验）** | 读写 `.GlobalPreferences.plist`（经典 tweak 路线，对 App Store App 不一定有效） |
| **HUD 选项** | 在「设置」页调 `MTL_HUD_SCALE`（缩放）、`MTL_HUD_ALIGNMENT`（位置）、`MTL_HUD_ELEMENTS`（显示内容），下次启动生效 |
| **诊断** | 设备型号/iOS 版本、上次写入时间、**写后是否重启过**、cfprefsd 当前值 |
| **cfprefsd 重载探测** | 绕过 cfprefsd 改本 App 自己的 plist 再读回来，判断它是否感知外部修改——决定"强退重开"够不够，还是必须重启 |
| **一键重启** | 通过 Diagnostics Relay 重启设备（cfprefsd 只在开机时重新读文件） |

写完后 App 会做 **SHA-256 回读校验**，确认设备上的文件就是写入的内容。

---

## 实现拆解

```
MetalUHD-iOS/
├── ios-app/                      SwiftUI App（约 2400 行）
│   ├── MetalUHDApp.swift         App 入口 / AppDelegate / ALGetGrappaToken 硬引用
│   ├── ContentView.swift         底栏：HUD / 日志 / 设置
│   ├── HUDHomeView.swift         HUD 页（自检 / 按 App / 全局 / 诊断）
│   ├── LogView.swift             日志页
│   ├── SettingsView.swift        设置页（配对 / 隧道 / 关于）
│   ├── HUDViewModel.swift        状态机、串行队列、App 列表、诊断
│   ├── HUDEngine.swift           全局 + 按 App 的读 → 备份 → 改 plist → 写 → 回读校验
│   ├── MetalHUDTest.swift        自带 Metal 渲染器 + 本进程 HUD 开关
│   ├── PairingController.swift   本机 RPPairing 主机（Bonjour + PIN 通知）
│   ├── Utilities.swift           配对期间保活、局域网权限探测
│   ├── GrappaHelper.[hm]         Grappa token（atc 认证需要）
│   ├── en.lproj / zh-Hans.lproj  界面本地化
│   └── Assets.xcassets           图标
├── rust-core/                    Rust FFI（airlift_ffi → AirliftFFI.xcframework）
│   └── src/exploit.rs            AirTraffic 逃逸管线 + 新增的 FFI
├── build-ios.sh                  Rust → xcframework
├── build-ipa.sh                  xcodebuild → 未签名 IPA
└── .github/workflows/build-ios.yml   CI 出 IPA
```

### 新增的 Rust FFI

原项目的 `al_exploit_write_dir()` 会**跳过以 `.` 开头的文件**（见 `exploit_write_dir` 里的
`filename.starts_with('.')`），而全局目标是隐藏文件 `.GlobalPreferences.plist`，所以补了专用函数：

| 函数 | 作用 |
|---|---|
| `al_exploit_read_file_to_path(pairing, dir, leaf, out_path, …)` | 读出原始字节存到 App 沙箱。底层是"搬出 → AFC 读 → 写回"，但**只要读到字节就一定写回**（重试 3 次；真读不出来时把文件留在 Media 并报告位置，绝不删除） |
| `al_exploit_write_file(pairing, dir, leaf, local_path, …)` | 按**精确文件名**写单个文件（点文件不跳过），复用已验证的 `exploit_write_single_file` 管线，失败重试 3 次 |
| `al_list_apps(pairing, …)` | 通过 InstallationProxy 列出用户 App：`bundle_id` / `name` / `container` / `version`（JSON） |
| `al_launch_app_with_hud(pairing, bundle_id, …)` | 通过 RSD 隧道连 `com.apple.coredevice.appservice`，带 `MTL_HUD_ENABLED=1` 启动目标 App（CoreDevice 的 `launchapplication`） |

`read_file_hash`（回读校验）沿用原项目。

### 写入流程

1. **读**现有文件（按 App 时文件可能不存在 —— 这是正常的，会新建）；
2. **备份**（全局：Documents/`GlobalPreferences-backup.plist`；按 App：Documents/`prefs-<bundle-id>.plist`，只存第一次）；
3. 解析 plist，**保留所有原有键**，只设置三个 HUD 键；
4. 写回设备（`al_exploit_write_file`）；
5. **回读比 SHA-256**；
6. 提示重启（cfprefsd 缓存）。

---

## 前置条件

- **iOS 18.0 – 27.2 beta 2**。Apple 在 **iOS 27.2 beta 3 修掉了底层 `airlift` 逃逸**，不要升过 beta 2。
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) 运行在**回环模式**（默认 `10.7.0.1`）。
  **不要填 `127.0.0.1`** —— 在 iOS 上会让 `remotepairingdeviced` 进入丢弃状态，只能关掉再打开开发者模式恢复。
- 一份**配对记录**：App 内 **Start pairing** 生成（PIN 会以通知形式发出），或导入现成的
  `metaluhd_pairing.plist` / `.mobiledevicepairing` / `.mobilepairing`。
- 官方「图书」App 装过并至少打开一次（`com.apple.atc` 同步需要）。

---

## 构建

Rust core 要交叉编译到 iOS，所以构建需要 **macOS + Xcode 16+**。没有 Mac 就让 GitHub 构建：

1. 把仓库推到 GitHub；
2. Actions → **Build unsigned IPA** → Run workflow（或改 `rust-core/`、`ios-app/`、`project.yml`、构建脚本时自动触发）；
3. CI 会把 **IPA 作为 GitHub Release 资产**发布（不再套 zip）。直接下载：

```sh
# 直接拿到 .ipa 文件（私有仓库需要已登录 gh）
gh release download v0.5.0 -R YiHoooong/MetalUHD-iOS -p MetalUHD.ipa -O MetalUHD.ipa

# 或者浏览器打开（需登录 GitHub）：
# https://github.com/YiHoooong/MetalUHD-iOS/releases/download/v0.5.0/MetalUHD.ipa
```

> GitHub Actions 的 artifact 永远是 zip，所以不再用 artifact；Release 资产就是原始 `.ipa`。

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

1. 打开 LocalDevVPN（回环模式），确认 App 里 **配对文件已就绪**；没有就 Start pairing 或导入。
2. （推荐）点 **打开 HUD 测试** —— 应该能看到 Metal 三角形 + 右上角 HUD。
   如果这里都没有 HUD，说明设备/系统层面不支持，先不用折腾游戏。
3. **先重启设备**（或者「诊断」里点测试 cfprefsd 重载，确认是不是缓存态）。
   这一步是为了清掉 cfprefsd 里目标 App 的旧缓存——先写后重启的话，
   重启过程中缓存可能把外部写入覆盖回去。
4. **不要打开游戏**。在 MetalUHD 里点 **加载已安装 App**，搜索并选中游戏。
5. **先点「启动并显示 HUD（免重启）」** —— 它用 CoreDevice 带 `MTL_HUD_ENABLED=1` 启动游戏，
   不重启也不改 defaults。成功的话游戏右上角直接出现 HUD。
6. 如果这一步失败（日志里 `coredevice appservice published: false` 或 `launchapplication failed`），
   再走 defaults 路线：点 **为这个 App 开启**，等 `write verified` + `cfprefsd view (<bundle>): true`，
   然后打开游戏。
7. HUD 应出现在右上角。

想关掉：选中同一个 App → **关闭**，推荐同样按「重启 → 写入 → 再开游戏」的顺序。

如果按这个顺序做完、Check 仍显示 `false`，那基本就是 iOS 对 App Store App 的限制
（HUD 的 defaults 路径只对开发签名/TestFlight 的 App 生效），需要走电脑端
`pymobiledevice3 developer dvt launch --env MTL_HUD_ENABLED=1` 这类注入路线。

---

## 风险与回滚

- **按 App 模式**：只改目标 App 的 defaults 文件，会保留它原有的键；首次写入前备份到
  Documents/`prefs-<bundle-id>.plist`。如果目标 App 的偏好文件读不出来，App 会拒绝替换。
- **全局模式**：会整体重写 `.GlobalPreferences.plist`。所有键都从原文件读出、原样写回，只改三个键；
  但"读 → 写"之间存在竞态可能。首次写入前备份到 Documents/`GlobalPreferences-backup.plist`，
  点 **恢复全局偏好备份** 可以还原。
- 万一偏好被写坏：重启后 iOS 会用默认值重建，**不会变砖**，但个性化设置可能丢失；
  用备份恢复即可。
- 传输中断/隧道掉线时 App 会报告失败；此时**不要反复重试**，先 Check 或重启确认设备状态。

---

## 排查

| 现象 | 处理 |
|---|---|
| `Stage verification failed` / 连不上 | LocalDevVPN 是否在跑、地址是否 `10.7.x.x`；换 `10.7.0.2` / `10.7.0.3` |
| `Grappa session could not be established` | 确认 `ALGetGrappaToken` 硬引用还在（见上） |
| 自检页也没有 HUD | 设备/系统不支持 HUD（或该 iOS 版本移除了），与写入无关 |
| 按 App 写入成功、重启后游戏仍无 HUD | 先 **Check** 该 App：三个键是否 true、`cfprefsd view` 是否 true；再换成「重启 → 写入 → 开游戏」的顺序重试；确认游戏确实是 Metal 渲染。若 Check 一直 false，参见"已知限制"里的 iOS 签名限制 |
| 全局模式 `true` / `cfprefsd: true` 但没 HUD | 已知现象：iOS 上 HUD 不读 global 域。改用按 App 模式 |
| 注销之后还是不生效 | 正常：respring 不重启 cfprefsd。看诊断里的 cfprefsd 探测，必要时重启设备 |
| 想确认 key 是否真的写进去了 | 点 Check；诊断卡片会显示上次写入时间和"写后是否重启" |

---

## 已知限制

- 依赖 AirTraffic 逃逸，**iOS 27.2 beta 3 起失效**。
- 生效需要**重启**（cfprefsd 缓存）；没有找到在设备上无重启刷新 cfprefsd 的办法。
- HUD 只在 **Metal 渲染**的 App 里出现；不是所有游戏都支持。
- Apple 文档说 iOS 上 HUD 只对**开发签名/TestFlight** 的 App 生效；自检页能出 HUD 也印证了这一点。
  所以 App Store 游戏**不要指望 defaults 路线**，优先用「启动并显示 HUD（免重启）」。
- CoreDevice 的 `launchapplication` 在部分 iOS 版本/设备上可能要求开发者镜像（DDI）已挂载；
  若日志显示 `coredevice appservice published: false` 或 `ServiceNotFound`，就只能走电脑端 DVT 路线。
- 写 App 容器属于设备端修改，App 内做了备份与校验，但仍建议先用非主力机验证。
- `rust-core/vendor/` 是上游 vendored 依赖，体积较大且包含与本 demo 无关的 FFI（`passthm`、zip、syslog 等），保留是为了少改动。

---

## 致谢

- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS) —— 配对流程、Rust core、构建脚本
- [airlift](https://github.com/0xjohnnydev/airlift) —— Johnny Franks：原始 PoC 与 ATAirlock 分析
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) —— Mak5er：回环隧道、Rust FFI core、Grappa token
- [idevice](https://github.com/jkcoxson/idevice) —— RSD/AFC/streaming_zip_conduit 管线
- [MetalHUDHelper](https://github.com/oliwonders/MetalHUDHelper) / [Nugget](https://github.com/leminlimez/Nugget) / [DukeX](https://github.com/MaftyManicEMU/DukeX) —— `MetalForceHudEnabled` 语义与键名变体的参考
- [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher)、[metalhud-ios-games](https://github.com/applegamingse/metalhud-ios-games) —— 环境变量路线与游戏支持情况

MIT，见 [LICENSE](LICENSE)（继承上游，版权归原作者）。
