# MetalUHD

[English](README.md)

MetalUHD 是一个运行在 iPhone 本机的 iOS 工具，用于在任意已安装应用（包括 App Store 应用）中
启用 Apple 的 Metal Performance HUD。它不需要电脑、不需要越狱，也不需要重启设备。

实现上复用了 [AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) 的 AirTraffic 沙箱逃逸，
通过 LocalDevVPN 回环隧道访问设备自身的服务，再借助 iOS 17+ 的 CoreDevice 应用服务，
以 `MTL_HUD_ENABLED=1` 启动目标应用。

> **状态：** 实验性。支持 iOS 18.0 至 iOS 27.2 beta 2。

---

## 工作原理

```
LocalDevVPN（回环模式）
        │
        ▼
RPPairing  →  RSD 隧道（终点在设备本机）
        │
        ├── InstallationProxy     列出已安装应用
        ├── SpringBoardServices   获取应用图标
        └── CoreDevice appservice 带环境变量启动应用
```

这一启动过程等价于在电脑上执行

```sh
devicectl device process launch --env MTL_HUD_ENABLED=1 <bundle-id>
```

区别是全部在手机上完成。CoreDevice 的 `com.apple.coredevice.appservice` 接受
`environmentVariables` 字典，HUD 开关正是通过它传给那些不读取 user defaults 的应用。

应用内还提供一个自检页面：渲染一个简易 Metal 视图，并为 MetalUHD 自身进程开启 HUD，
用于在不依赖第三方应用的情况下确认 HUD 能力。

## 为什么不使用 preferences 方案

Apple 将 `MetalForceHudEnabled` 记录为应用域 user defaults，并在 iOS 上将 HUD 限制为
开发签名或 TestFlight 应用。本机验证结果与之一致：

| 方式 | 结果 |
|---|---|
| 写入 `.GlobalPreferences.plist` 后重启设备 | `cfprefsd` 显示 `true`，App Store 游戏无 HUD |
| 写入目标应用自己的 `Library/Preferences/<bundle>.plist` | 同样无效，游戏不读取 |
| 通过 CoreDevice 以 `MTL_HUD_ENABLED=1` 启动 | HUD 立即出现，无需重启 |

因此 preferences 相关代码已从应用中移除。
`MTL_HUD_ELEMENTS` 也未开放：当前 iOS 版本对 macOS 上支持的命名布局只会渲染出一条空背景。

## 功能

- **应用网格。** 四列布局，显示真实图标与名称。点击图标会结束该应用（如正在运行）
  并带 HUD 重新启动。
- **隧道检测。** 每次设备操作前先探测 LocalDevVPN；未运行时直接提示打开，
  而不是等待后失败。
- **HUD 选项。** 可配置 `MTL_HUD_SCALE` 与 `MTL_HUD_ALIGNMENT`，下次启动生效。
- **HUD 自检。** 用 Metal 渲染三角形，并为应用自身进程开启 HUD。
- **配对与诊断。** RPPairing 主机、配对文件导入/导出、回环地址、运行日志与设备信息。

## 环境要求

- iOS 18.0 – 27.2 beta 2。Apple 在 iOS 27.2 beta 3 修复了底层的 `airlift` 逃逸，
  更高版本不受支持。
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) 运行在回环模式。默认地址为
  `10.7.0.1`；不要使用 `127.0.0.1`，否则 `remotepairingdeviced` 会进入拒绝状态，
  只能通过关闭再打开开发者模式恢复。
- 一份配对记录。可以在应用内生成（PIN 会以通知形式送达，因为此时你正在设置中操作），
  或从其他侧载工具导入。
- Apple Books 已安装并至少打开过一次，以便 `com.apple.atc` 允许同步。

## 构建

Rust core 需要交叉编译到 iOS，因此本地构建需要 macOS 与 Xcode 16 或更高版本。

**GitHub Actions（无需 Mac）：**

1. 将仓库推送到 GitHub。
2. 运行 **Build unsigned IPA** 工作流，或推送涉及 `rust-core/`、`ios-app/`、`project.yml`、
   构建脚本或工作流的改动。
3. IPA 会作为 GitHub Release 资产发布，而不是 zip 附件。

```sh
gh release download v0.8.5 -R YiHoooong/MetalUHD-iOS -p MetalUHD.ipa -O MetalUHD.ipa
```

**本地构建：**

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # build/MetalUHD.ipa
```

IPA 刻意不签名，请使用与其它侧载应用相同的工具签名（AltStore、SideStore、Sideloadly、
TrollStore 等）。

> `MetalUHDApp.swift` 中对 `ALGetGrappaToken` 的硬引用必须保留。Rust core 通过
> `dlsym` 查找该符号；没有静态引用时链接器可能将其剔除，之后每次同步都会以
> *“Grappa session could not be established”* 失败。

## 使用

1. 以回环模式启动 LocalDevVPN。
2. 打开 MetalUHD。配对文件就绪后应用列表会自动加载。
3. 点击游戏图标。若该应用正在运行，会先结束，再以 `MTL_HUD_ENABLED=1` 启动。
4. 在 **设置 → HUD** 中调整缩放或位置，下次启动生效。

不需要重启设备。

HUD 绘制在应用自己的 drawable 中，清晰度取决于游戏的渲染分辨率。开启动态分辨率缩放的游戏
会显得偏软。可调项只有缩放与位置；内容布局（`MTL_HUD_ELEMENTS`）在当前 iOS 版本不可用。

## 风险与限制

- 点击图标会结束正在运行的应用，可能丢失未保存的进度。
- 部分带反作弊的游戏可能把开发者方式的启动视为异常。
- 该方案依赖 airlift 逃逸，iOS 27.2 beta 3 起失效。
- 部分 iOS 版本上 CoreDevice 的 `launchapplication` 可能要求已挂载开发者镜像。
  如果日志出现 `coredevice appservice published: false` 或 `launchapplication failed`，
  请改用电脑端方案：
  `pymobiledevice3 developer dvt launch --env MTL_HUD_ENABLED=1 <bundle-id>`。

## 仓库结构

```
.
├── ios-app/                  SwiftUI 应用
│   ├── ContentView.swift     底栏：HUD / 日志 / 设置
│   ├── HUDHomeView.swift     状态卡片与应用网格
│   ├── LogView.swift         诊断与运行日志
│   ├── SettingsView.swift    配对、HUD 选项、隧道、关于
│   ├── HUDViewModel.swift    状态、应用列表、图标、启动
│   ├── HUDEngine.swift       InstallationProxy / SpringBoard / CoreDevice
│   ├── MetalHUDTest.swift    应用内 HUD 自检
│   ├── PairingController.swift
│   └── Assets.xcassets/      应用图标（由 tools/make-icon.py 生成）
├── rust-core/                Rust FFI，编译为 AirliftFFI.xcframework
├── tools/
│   ├── icon-source.png       图标素材
│   └── make-icon.py          图标生成脚本
├── build-ios.sh
├── build-ipa.sh
└── .github/workflows/build-ios.yml
```

## 致谢

- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS)：配对流程、Rust core 与构建脚本。
- [airlift](https://github.com/0xjohnnydev/airlift)（Johnny Franks）：原始 PoC 与 ATAirlock 分析。
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（Mak5er）：回环隧道、Rust FFI core 与 Grappa token。
- [idevice](https://github.com/jkcoxson/idevice)：RSD、AFC、CoreDevice 与 InstallationProxy 管线。
- [MetalHUDHelper](https://github.com/oliwonders/MetalHUDHelper)、
  [Nugget](https://github.com/leminlimez/Nugget) 与
  [DukeX](https://github.com/MaftyManicEMU/DukeX)：`MetalForceHudEnabled` 及其键名变体的参考。
- [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher)：`MTL_HUD_ENABLED`
  注入路线的参考。

## 许可证

MIT，见 [LICENSE](LICENSE)。部分代码来自上述项目，版权归原作者所有。
