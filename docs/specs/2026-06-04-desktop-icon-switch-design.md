# 桌面端换图标 + 各端同步 设计

> 状态：已经用户确认（范围①、预设+自选图片、自选图内联进偏好同步=方案A）。
> 日期：2026-06-04。来源对话：将「换图标」从 Android-only 扩到 Windows/macOS，并让选择跨设备同步。

## 1. 目标与非目标

**目标**
- Windows / macOS 支持切换 App 图标：内置预设（default / full / minimal）+ 用户自选图片。
- 桌面端"换图标"= 改**运行中程序**的图标：Windows 窗口 + 任务栏图标（`WM_SETICON`），macOS 程序坞 Dock 图标（`NSApp.applicationIconImage`）。每次启动重新套用，重启不丢。
- 图标选择 + 自选图片**跨设备同步**：在一台设备上选定，经现有同步系统传到其它设备，各端按自己平台的方式套用。

**非目标（明确不做）**
- 不改 exe（资源管理器里）/ .app（访达里）的**磁盘文件图标**。原因：Windows 需重写运行中 exe 的 PE 资源（被占用、破坏签名、绿色版无快捷方式可改、图标缓存不刷新）；macOS `NSWorkspace.setIcon` 会在 bundle 内塞 `Icon\r` 破坏已签名/公证 .app 的封签。两端都碎，已评估否决。
- 不动 Linux / iOS：继续显示"不支持切换图标"。
- 不引入 SyncAssetStore 新资产类型（自选图走偏好内联，方案A）。

## 2. 现状（代码事实）

- UI：`hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart`
  - `iconAssetMap`（default/hibiki_full/hibiki_minimal → `assets/meta/*.png`）。
  - `build()` 中 `if (Platform.isAndroid)` 显示图标网格，`else` 显示 `t.icon_shortcut_unsupported`。
  - 预设切换 `_switchPreset(key)` → channel `switchPresetIcon` → 成功后 `SharedPreferences.setString('app_icon_preset', key)`。
  - 自选 `_pickCustomIcon()` → `image_picker` → channel `createCustomShortcut(bytes)`（**安卓语义是创建固定快捷方式，与桌面不同**）。
- Channel：`hibiki/lib/src/utils/misc/channel_constants.dart:22` → `MethodChannel('<prefix>/icon_switch')`。
- 安卓原生：`android/app/src/main/java/app/hibiki/reader/IconSwitchHelper.java`
  - `getCurrentIcon()→String`、`switchPresetIcon(targetKey)→bool`、`isCustomShortcutSupported()→bool`、`createCustomShortcut(byte[])→bool`（activity-alias 切换 / pinned shortcut）。
- Windows runner：`windows/runner/win32_window.cpp:96` 用 `LoadIcon(hInstance, MAKEINTRESOURCE(IDI_APP_ICON))` 设 `WNDCLASS.hIcon`；`Runner.rc:55` `IDI_APP_ICON ICON "resources\\app_icon.ico"`；`resource.h:5` `IDI_APP_ICON 101`。
- macOS runner：`macos/Runner/MainFlutterWindow.swift`（`NSWindow` 子类）、`AppDelegate.swift`。
- 存储分层：`app_icon_preset` 现在在 **SharedPreferences（设备本地，不同步）**。同步搬的是 Drift `preferences` 表。
- 同步选择性：`hibiki/lib/src/sync/backup_service.dart:389-394` —— 恢复 settings 层时 preferences 表大多数键**保留本地**，只有 `audiobook_pos_%` 白名单键跨设备。
- 同步组件：`lib/src/sync/{sync_asset_store,sync_manager,sync_orchestrator,backup_service}.dart`。

## 3. 设计

### 3.1 存储单一真相源迁移
- `app_icon_preset` 从 SharedPreferences → Drift `preferences` 表（经 `PreferencesRepository`）。新增键：
  - `app_icon_preset`（String）：`default` / `hibiki_full` / `hibiki_minimal` / `custom`。
  - `app_icon_custom_png`（String，仅 `custom` 时有值）：自选图缩放后 PNG 的 base64。
- **一次性迁移（Never break userspace）**：首次读取时若 Drift 无 `app_icon_preset` 而 SharedPreferences 有，则搬过来并删旧键。安卓老用户的当前选择不丢。

### 3.2 跨设备同步
- 把 `app_icon_preset` 和 `app_icon_custom_png` 加进 `backup_service` 的跨设备白名单（与 `audiobook_pos_%` 同级处理），让它们随 settings 层同步而非被当本地设置保留。
- 自选图（方案A）：缩到不超过 256×256 PNG（app 图标足够），base64 存 `app_icon_custom_png`，搭偏好同步顺风车，**不新增同步管线**。
- 冲突：last-write-wins（与现有偏好同步一致；图标非高频写，不接入 SyncConflictPrompter）。

### 3.3 平台 channel 契约（`icon_switch`）
桌面新增/统一方法（安卓维持现有实现，语义对齐）：
- `getCurrentIcon() → String`：返回当前 preset key。**真相源是 Drift `app_icon_preset`**（Dart 侧据此判定"当前选中"）；`getCurrentIcon` 仅用于安卓侧把 native alias 实际状态与 Drift 偏好对账（不一致时以 Drift 为准重套用）。桌面端不依赖它判定当前值。
- `applyIcon({preset: String, customPng: Uint8List?}) → bool`：统一套用入口。
  - preset ∈ default/full/minimal → 用内置图标；preset == custom → 用 `customPng`。
  - 桌面据此套用窗口/任务栏(Win) / Dock(Mac)；安卓据此走 alias / shortcut。
  > 用 `applyIcon` 统一入口取代桌面分别调 `switchPresetIcon`/`setCustomIcon`，消除分支特例。安卓侧把 `applyIcon` 适配到现有 alias/shortcut 实现。

### 3.4 各端套用
- **Windows**（`win32_window.cpp` + handler）：
  - 预设：把 default/full/minimal 各打一个 `.ico` 进 `windows/runner/resources/`，新增资源 ID；`LoadImage(..., IMAGE_ICON, LR_DEFAULTSIZE)` 或按资源 ID 加载。
  - 自选：`customPng` 字节 → GDI+/`CreateIconIndirect` 转 `HICON`。
  - 套用：`SendMessage(hwnd, WM_SETICON, ICON_BIG, hIcon)` + `ICON_SMALL`。保存 `HICON` 句柄，切换时销毁旧的防泄漏。
- **macOS**（`MainFlutterWindow`/`AppDelegate` + handler）：
  - 预设/自选统一 `NSApp.applicationIconImage = NSImage(data:/contentsOfFile:)`。预设图随 bundle，自选用 `customPng`。
- **Android**：`applyIcon` 适配到 `IconSwitchHelper`（preset→`switchPresetIcon`，custom→现有 shortcut 路径）。

### 3.5 启动 & 同步后重套用
- `hibiki/lib/main.dart` 桌面分支（Win/Mac）启动时读偏好 → 调 `applyIcon` 重套用一次（重启持久）。
- 同步 apply 后（`backup_service` restore 完成 / `sync_orchestrator` 收敛后）触发一次重套用，让同步过来的新图标即时生效。失败静默（尽力而为，不阻塞）。

### 3.6 UI 改动
- `miscellaneous_settings_page.dart`：门控 `if (Platform.isAndroid)` → `if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)`。Linux/iOS 仍"不支持"。
- 预设网格预览图（full/minimal PNG）在桌面包里需可显示 → 这两张 PNG 重新打回 Windows/macOS 包（见 §5 体积副作用）。
- 自选走桌面文件选择（`file_picker` 或 `image_picker` 桌面实现），选后缩放→base64→存偏好→`applyIcon`。

## 4. 错误处理
- channel 返回 bool；失败复用现有 snackbar 文案（`icon_switch_success` / `icon_shortcut_unsupported`）。
- 启动/同步后重套用失败：静默 + 错误日志，不阻塞启动。
- 自选图解码失败/过大：缩放阶段兜底，超限拒绝并提示。

## 5. 体积副作用（已与用户确认接受）
- 启用桌面 picker 需把 `launcher_icon_full.png`(2.4M)/`launcher_icon_minimal.png`(240K) 预览图重新打进桌面包，抵消之前 ~2.6MB 优化。`icon-android12.png`/`launcher_source.png` 仍可继续从产物剔除。

## 6. 测试策略
- **widget 测试**：桌面平台下设置页显示图标网格（非"不支持"）；选预设 → channel 收到 `applyIcon{preset}`；选自选图 → 收到 `applyIcon{customPng}`；偏好写穿 Drift。
- **迁移测试**：SharedPreferences 有旧 `app_icon_preset`、Drift 无 → 首读后 Drift 有、旧键清除。
- **同步测试**：`app_icon_preset` + `app_icon_custom_png` 在 backup/restore 往返后跨设备保留（对照非白名单键保持本地）。
- **源码守卫**：断言设置页门控含 Windows/macOS；断言两键在同步白名单内。
- **真机视觉复测（用户）**：Win 任务栏/Mac Dock 图标真变 + 重启保持 + 两机同步生效。离屏抓不到任务栏/Dock，需肉眼。

## 7. 影响文件清单
- `hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart`（门控 + 自选桌面路径 + applyIcon 调用）
- `hibiki/lib/main.dart`（桌面启动重套用）
- `hibiki/lib/src/models/preferences_repository.dart`（新增图标键 getter/setter）
- `hibiki/lib/src/sync/backup_service.dart`（同步白名单加两键）
- 同步收敛后重套用钩子（`sync_orchestrator.dart` 或 `app_model` 同步回调）
- `windows/runner/{win32_window.cpp,win32_window.h,Runner.rc,resource.h}` + 预设 `.ico` + channel handler
- `macos/Runner/{MainFlutterWindow.swift / AppDelegate.swift}` + 预设图 + channel handler
- `android/.../IconSwitchHelper.java` + MainActivity handler（`applyIcon` 适配）
- `hibiki/pubspec.yaml`（确保 full/minimal 预览图入桌面包）
- 测试：widget / 迁移 / 同步 / 源码守卫
