# 桌面端换图标（Win/Mac 本地，不跨设备同步）设计

> 状态：已经用户确认。范围 = ①运行时图标 + 预设 + 自选图片；**不做跨设备同步（方案C）**；不做磁盘文件图标（②否决）。
> 日期：2026-06-04。来源对话：将「换图标」从 Android-only 扩到 Windows/macOS。
>
> **同步决策记录**：曾考虑让图标选择跨设备同步，但子代理排查确认本仓库**没有"同步单个全局设置项"的机制**——正常自动同步是按书/按资产模型，`audiobook_pos` 也是搭"每本书的有声书资产文件"传播，App 图标无此载体。真·后台自动同步需新建"全局偏好同步"子系统（成本不小）。用户选择 **C：不同步**，图标选择各设备各自设。

## 1. 目标与非目标

**目标**
- Windows / macOS 支持切换 App 图标：内置预设（default / full / minimal）+ 用户自选图片。
- 桌面端"换图标"= 改**运行中程序**的图标：Windows 窗口 + 任务栏图标（`WM_SETICON`），macOS 程序坞 Dock 图标（`NSApp.applicationIconImage`）。每次启动重新套用，重启不丢。

**非目标（明确不做）**
- **不跨设备同步**：图标选择是设备本地状态，各设备独立。
- 不改 exe（资源管理器里）/ .app（访达里）的**磁盘文件图标**。原因：Windows 需重写运行中 exe 的 PE 资源（被占用、破坏签名、绿色版无快捷方式可改、图标缓存不刷新）；macOS `NSWorkspace.setIcon` 会在 bundle 内塞 `Icon\r` 破坏已签名/公证 .app 的封签。两端都碎，已评估否决。
- 不动 Linux / iOS：继续显示"不支持切换图标"。
- 不碰 Drift `preferences` 表 / 同步子系统 / SharedPreferences→Drift 迁移（保持现状，零破坏）。

## 2. 现状（代码事实）

- UI：`hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart`
  - `iconAssetMap`（default/hibiki_full/hibiki_minimal → `assets/meta/*.png`）。
  - `build()` 中 `if (Platform.isAndroid)` 显示图标网格，`else` 显示 `t.icon_shortcut_unsupported`。
  - 预设切换 `_switchPreset(key)` → channel `switchPresetIcon` → 成功后 `SharedPreferences.setString('app_icon_preset', key)`。
  - 自选 `_pickCustomIcon()` → `image_picker` → channel `createCustomShortcut(bytes)`（**安卓语义是创建固定快捷方式**，无持久化预设图）。
- Channel：`hibiki/lib/src/utils/misc/channel_constants.dart:22` → `MethodChannel('<prefix>/icon_switch')`。
- 安卓原生：`android/app/src/main/java/app/hibiki/reader/IconSwitchHelper.java`
  - `getCurrentIcon()→String`、`switchPresetIcon(targetKey)→bool`、`isCustomShortcutSupported()→bool`、`createCustomShortcut(byte[])→bool`（activity-alias 切换 / pinned shortcut）。
- Windows runner：`windows/runner/win32_window.cpp:96` 用 `LoadIcon(hInstance, MAKEINTRESOURCE(IDI_APP_ICON))` 设 `WNDCLASS.hIcon`；`Runner.rc:55` `IDI_APP_ICON ICON "resources\\app_icon.ico"`；`resource.h:5` `IDI_APP_ICON 101`。
- macOS runner：`macos/Runner/MainFlutterWindow.swift`（`NSWindow` 子类）、`AppDelegate.swift`。
- 存储：`app_icon_preset` 在 SharedPreferences（设备本地）。**保持不变**——`shared_preferences` 桌面端原生支持（落 app support 目录 JSON），无需迁移。
- 依赖：`image: ^4.3.0`（缩放/编码）、`file_picker: ^8.0.0`、`image_picker: ^0.8.7` 均已在 `pubspec.yaml`。

## 3. 设计

### 3.1 存储（设备本地，零迁移）
- 预设选择：沿用 `SharedPreferences` 的 `app_icon_preset`（值 `default`/`hibiki_full`/`hibiki_minimal`/`custom`）。安卓现状不动。
- 自选图片：缩放到 **256×256** PNG，存成**本地文件** `<appSupportDir>/app_icon_custom.png`（用 `path_provider.getApplicationSupportDirectory()`）。预设值记 `custom`，重套用时读该文件。文件缺失 → 回落 `default`。
- 不进 Drift、不进备份、不进同步——天然设备本地。

### 3.2 平台 channel 契约（`icon_switch`）
桌面新增/统一方法（安卓维持现有实现，语义对齐）：
- `getCurrentIcon() → String`：返回当前 preset key。真相源是 SharedPreferences `app_icon_preset`；`getCurrentIcon` 仅用于安卓侧把 native alias 实际状态对账，桌面端不依赖它判定当前值。
- `applyIcon({preset: String, customPngPath: String?}) → bool`：统一套用入口。
  - preset ∈ default/full/minimal → 用内置图标；preset == custom → 读 `customPngPath` 文件。
  - 桌面据此套用窗口/任务栏(Win) / Dock(Mac)；安卓据此走 alias / shortcut。
  > 用 `applyIcon` 统一入口取代桌面分别调 `switchPresetIcon`/`setCustomIcon`，消除分支特例。安卓侧把 `applyIcon` 适配到现有 alias/shortcut 实现。

### 3.3 各端套用
- **Windows**（`win32_window.cpp` + handler）：
  - 预设：把 default/full/minimal 各打一个 `.ico` 进 `windows/runner/resources/`，新增资源 ID；按资源 ID `LoadImage(..., IMAGE_ICON)` 加载。
  - 自选：读 `customPngPath` 字节 → GDI+ 解码 → `CreateIconIndirect` 转 `HICON`。
  - 套用：`SendMessage(hwnd, WM_SETICON, ICON_BIG, hIcon)` + `ICON_SMALL`。保存自选 `HICON` 句柄，切换时销毁旧的防泄漏（预设资源图标由系统管，不销毁）。
- **macOS**（`MainFlutterWindow`/`AppDelegate` + handler）：
  - 预设/自选统一 `NSApp.applicationIconImage = NSImage(...)`。预设图随 bundle（Assets 或读 flutter_asset），自选用 `customPngPath`。
- **Android**：`applyIcon` 适配到 `IconSwitchHelper`（preset→`switchPresetIcon`，custom→现有 shortcut 路径）。保持现有行为，不回归。

### 3.4 启动时重套用
- `hibiki/lib/main.dart` 桌面分支（Win/Mac）启动时读 `app_icon_preset` → 调 `applyIcon` 重套用一次（重启持久）。失败静默（尽力而为，不阻塞启动）。

### 3.5 UI 改动
- `miscellaneous_settings_page.dart`：门控 `if (Platform.isAndroid)` → `if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)`。Linux/iOS 仍显示"不支持"。
- 预设网格预览图（full/minimal PNG）在桌面包里需可显示 → 这两张 PNG 重新打回 Windows/macOS 包（见 §5 体积副作用）。
- 自选：桌面用 `file_picker`（`image_picker` 桌面支持弱），选图 → `image` 包解码+缩 256→编码 PNG→写 `app_icon_custom.png`→`applyIcon(preset:'custom', customPngPath:...)`→存 `app_icon_preset='custom'`。

### 3.6 256×256 上限依据（非随意取值）
(1) Windows `.ico` 格式单图硬上限就是 256×256（尺寸字段 1 字节，0=256），>256 系统也用不了；(2) macOS Dock 最大尺寸 Retina @2x = 256px；(3) 框住本地文件大小。任选图无论多大一律缩到 ≤256。

## 4. 错误处理
- channel 返回 bool；失败复用现有 snackbar 文案（`icon_switch_success` / `icon_shortcut_unsupported`）。
- 启动重套用失败 / 自选文件缺失：静默回落 `default` + 错误日志，不阻塞启动。
- 自选图解码失败/过大：缩放阶段兜底，超限/解码失败提示并不改当前图标。

## 5. 体积副作用（已与用户确认接受）
- 启用桌面 picker 需把 `launcher_icon_full.png`(2.4M)/`launcher_icon_minimal.png`(240K) 预览图重新打进桌面包，抵消之前 ~2.6MB 优化。`icon-android12.png`/`launcher_source.png` 仍可继续从产物剔除。

## 6. 测试策略
- **widget 测试**（桌面平台覆写 `debugDefaultTargetPlatformOverride` 或 `Platform` 注入）：设置页显示图标网格（非"不支持"）；选预设 → channel 收到 `applyIcon{preset}`；选自选图 → 走缩放+写文件+`applyIcon{customPngPath}` + 存 `app_icon_preset`。
- **缩放单测**：喂一张 >256 的图 → 输出 PNG ≤256×256（纯函数 `resizeIconPng(bytes)→bytes`，可脱平台测）。
- **回落测试**：preset==custom 但自选文件不存在 → `applyIcon` 入参回落 default（Dart 侧决策，可单测）。
- **源码守卫**：断言设置页门控含 `Platform.isWindows`/`Platform.isMacOS`。
- **真机视觉复测（用户）**：Win 任务栏/Mac Dock 图标真变 + 重启保持 + 自选图生效。离屏抓不到任务栏/Dock，需肉眼。

## 7. 影响文件清单
- `hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart`（门控放开 + 桌面自选路径 + `applyIcon` 调用 + 缩放/写文件）
- `hibiki/lib/main.dart`（桌面启动重套用）
- 新增 Dart helper（如 `lib/src/utils/misc/app_icon_service.dart`）：封装 `applyIcon` channel 调用 + `resizeIconPng` 纯函数 + 自选文件路径管理（集中逻辑，便于测试）
- `windows/runner/{win32_window.cpp,win32_window.h,Runner.rc,resource.h,CMakeLists.txt}` + 预设 `.ico`（default/full/minimal）+ `icon_switch` channel handler（在 `flutter_window.cpp` 注册）
- `macos/Runner/{MainFlutterWindow.swift / AppDelegate.swift}` + 预设图 + `icon_switch` channel handler
- `android/.../IconSwitchHelper.java` + `MainActivity`（`applyIcon` 适配到现有 alias/shortcut，保持行为）
- `hibiki/pubspec.yaml`（确保 full/minimal 预览图入桌面包）
- 测试：widget / 缩放单测 / 回落单测 / 源码守卫
