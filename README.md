# MetalUHD (iOS)

在 iPhone **本机**给任意 App（包括 App Store 游戏）打开 Apple 官方的 **Metal Performance HUD**
（FPS / 帧时间 / GPU 时间的叠加层）——不需要 Mac、不需要 Xcode、不需要越狱、**不需要重启设备**。

做法：复用 [AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) 的 AirTraffic 沙箱逃逸
（来自 [airlift](https://github.com/0xjohnnydev/airlift) / [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)），
通过 LocalDevVPN 回环隧道连上设备自己的 RSD 服务，再用 iOS 17+ 的 **CoreDevice**
（`com.apple.coredevice.appservice`）带环境变量 `MTL_HUD_ENABLED=1` 启动目标 App。

> 这等价于在电脑上执行 `devicectl device process launch --env MTL_HUD_ENABLED=1 <bundle id>`，
> 但完全在手机上完成。

---

## 为什么不用写 preferences 的旧方案

Apple 文档说 iOS 上 HUD 开关写在 **App 自己的 standard user defaults** 里；但它同时写着
"iOS 上 HUD 只对开发签名/TestFlight 的 App 生效"。实测：

- 把 `MetalForceHudEnabled` 写进全局域 / 目标 App 的 defaults，重启后 App Store 游戏**依然没有 HUD**；
- 而 CoreDevice 带 `MTL_HUD_ENABLED=1` 启动后，**王者荣耀直接出 HUD**（本项目的真机验证结果）。

所以旧的两条 defaults 路线已经**从界面和引擎里删掉**，只保留环境变量注入这一条。

---

## 功能

| 功能 | 说明 |
|---|---|
| **桌面式 App 网格** | 4 列图标 + 名称，点一下图标就结束可能正在运行的实例，并带 `MTL_HUD_ENABLED=1` 重新启动它 |
| **Liquid Glass 风格** | 分组列表 + 毛玻璃搜索框，卡片使用系统分组配色 |
| **LocalDevVPN 检测** | 启动/加载前先探测回环网关，没开就弹窗提示去打开，而不是转圈后失败 |
| **HUD 选项** | 设置页调 `MTL_HUD_SCALE`（缩放，留空 = Apple 默认 0.2）和 `MTL_HUD_ALIGNMENT`（位置），下次启动生效 |
| **HUD 自检** | 设置页里用 Metal 画一个三角形并在本 App 进程打开 HUD，用来确认设备上 HUD 本身可用 |
| **配对 / 隧道** | 本机 RPPairing、导入/导出配对文件、LocalDevVPN 回环地址 |
| **日志 / 诊断** | 日志页顶部显示设备、上次启动、配对状态，下面是完整运行日志 |

`MTL_HUD_ELEMENTS`（显示内容布局）在这个 iOS 版本上会导致 HUD 只剩一条空黑色横条，所以不提供。

---

## 目录结构

```
MetalUHD-iOS/
├── ios-app/
│   ├── ContentView.swift         底栏：HUD / 日志 / 设置
│   ├── HUDHomeView.swift         状态卡片 + 4 列 App 网格（点图标即启动）
│   ├── LogView.swift             诊断 + 运行日志
│   ├── SettingsView.swift        原生分组列表：配对 / HUD / 隧道 / 关于
│   ├── HUDViewModel.swift        状态、App 列表与图标、启动
│   ├── HUDEngine.swift           InstallationProxy 列表 + SpringBoard 图标 + CoreDevice 启动
│   ├── MetalHUDTest.swift        自带 Metal 渲染器（HUD 自检）
│   ├── PairingController.swift   本机 RPPairing 主机
│   ├── Utilities.swift           配对保活 / 局域网权限
│   ├── GrappaHelper.[hm]         Grappa token（atc 认证）
│   └── en.lproj / zh-Hans.lproj  本地化
├── rust-core/                    Rust FFI（AirliftFFI.xcframework）
└── .github/workflows/build-ios.yml   CI：Rust → IPA → Release 资产
```

### 用到的 Rust FFI

| 函数 | 作用 |
|---|---|
| `al_list_apps` | InstallationProxy 列出用户 App（bundle_id / name / container / version，JSON） |
| `al_cache_app_icons` | SpringBoardServices 批量取 App 图标，写成 `<dir>/<bundle-id>.png` |
| `al_launch_app_with_hud` | CoreDevice `launchapplication`，带 `MTL_HUD_ENABLED=1`（+ 可选 `MTL_HUD_SCALE` / `MTL_HUD_ALIGNMENT`） |

`rust-core` 里还保留着早期 defaults 路线用到的读写 plist / respring 等 FFI，App 已经不再调用。

---

## 前置条件

- **iOS 18.0 – 27.2 beta 2**（Apple 在 **iOS 27.2 beta 3 修掉了底层 `airlift` 逃逸**；CoreDevice 路线本身也依赖开发者模式）。
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) 运行在**回环模式**（默认 `10.7.0.1`）。
  **不要填 `127.0.0.1`**。
- 一份**配对记录**：App 内生成（PIN 会以通知形式发出），或导入现成的
  `metaluhd_pairing.plist` / `.mobiledevicepairing` / `.mobilepairing`。
- 官方「图书」App 装过并至少打开一次（`com.apple.atc` 同步需要）。

---

## 构建（CI 直接产出 IPA）

推送到 GitHub 后，Actions → **Build unsigned IPA** → Run workflow；
CI 会把 **`MetalUHD.ipa` 作为 GitHub Release 资产**发布（不是 zip artifact）：

```sh
# 直接下载 .ipa
gh release download v0.8.1 -R YiHoooong/MetalUHD-iOS -p MetalUHD.ipa -O MetalUHD.ipa
```

浏览器（私有仓库需登录）：

```
https://github.com/YiHoooong/MetalUHD-iOS/releases/download/v0.8.1/MetalUHD.ipa
```

Mac 上手动构建：

```sh
brew install xcodegen
./build-ios.sh
./build-ipa.sh Release
```

IPA 是**未签名**的，用你平时签 AirliftSilence 的工具签名。

> [!IMPORTANT]
> `MetalUHDApp.swift` 里对 `ALGetGrappaToken` 的硬引用别删。Rust 用 `dlsym` 找它，
> 没有硬引用链接器可能把它丢掉，之后每次同步都会以 *"Grappa session could not be established"* 失败。

---

## 使用

1. 打开 LocalDevVPN（回环模式），在「设置」页确认配对文件就绪；没有就 Start pairing 或导入。
2. 回到 **HUD** 页，App 列表会自动加载（也可点右上角刷新）。如果 LocalDevVPN 没开，会直接弹窗提示去打开。
3. **点一下游戏图标** —— 已经在运行会被结束，然后带 HUD 启动。
4. 游戏右上角出现 FPS / 帧时间 / GPU 时间面板，**不需要重启设备**。

「设置 → HUD 选项」可以调：

- **缩放**：留空 = Apple 默认 0.2；建议 `0.3`–`0.4`；
- **位置**：`tr`（右上）/ `tl` / `tc` / `cl` / `c` / `cr` / `bl` / `bc` / `br`。

---

## HUD 为什么会糊

Apple 的 [MetalPerformanceHUD 手册](https://keith.github.io/xcode-man-pages/MetalPerformanceHUD.1.html) 写明：
HUD 绘制在 **App 自己的 drawable** 里，`MTL_HUD_SCALE` 是 drawable 宽度的比例（0.1–1.0，默认 0.2，最小 300px）。
游戏开了动态分辨率/渲染缩放时，HUD 会跟着整帧一起被放大，于是发虚。

- 没有"提高 HUD 分辨率"的开关，这是 HUD 的设计；
- 能调的只有缩放、位置，以及**游戏自己的画面分辨率/画质**；
- 如果 HUD 变成一条空的横线：通常是 `MTL_HUD_ELEMENTS` 或异常 drawable 尺寸，本 App 已不再传前者。

---

## 风险与限制

- 每次点 App 都会**强制结束**它再启动（避免旧实例不带环境变量）。有进度没保存的游戏注意。
- 少数带反作弊的游戏可能把"开发者方式启动"当成异常；遇到闪退请告诉我。
- 依赖 AirTraffic 逃逸：**iOS 27.2 beta 3 起失效**。
- CoreDevice `launchapplication` 在部分 iOS 版本/设备上可能要求开发者镜像（DDI）已挂载；
  失败时日志会显示 `coredevice appservice published: false` 或 `launchapplication failed`，那就只能走电脑端
  `pymobiledevice3 developer dvt launch --env MTL_HUD_ENABLED=1 <bundle id>`。
- `rust-core/vendor/` 是上游 vendored 依赖，体积较大。

---

## 致谢

- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS) —— 配对、Rust core、构建脚本
- [airlift](https://github.com/0xjohnnydev/airlift) / [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) —— 逃逸与隧道
- [idevice](https://github.com/jkcoxson/idevice) —— RSD / AFC / CoreDevice / InstallationProxy
- [iOS-MetalHUD-Launcher](https://github.com/wurezhwe/iOS-MetalHUD-Launcher) —— `MTL_HUD_ENABLED` 注入路线的参考

MIT，见 [LICENSE](LICENSE)（继承上游，版权归原作者）。
