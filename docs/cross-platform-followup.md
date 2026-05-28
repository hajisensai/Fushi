# 跨平台可维护性 — 后续待办

本文件记录 2026-05-29 完成的跨平台可维护性优化（plan: `docs/superpowers/plans/2026-05-28-cross-platform-maintainability.md`，Tasks 1-22 全部执行完毕、最终审查通过）之后**仍未收尾**的项。这些项被**刻意推迟**，主要原因是当时有另一个 agent 会话在同一 `develop` 分支并发改动 `lib/src/sync/` 与多个 UI 文件，强行批量改写会冲击对方工作。

## 解除条件（开始前必须满足）

1. 并发 sync 模块工作已落地：`flutter pub get` 后 `lib/src/sync/` 不再有缺包编译错误（`dartssh2` / `ftpconnect` / `multicast_dns` 已正确加入 `pubspec.yaml` 并安装）。
2. 确认 `develop` 上不再有其他 agent 会话并发提交，避免再次出现提交边界污染。

验证命令：
```bash
cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze 2>&1 | grep -c error
# 期望：0（当前因 sync 模块缺包约 56 个 error）
```

---

## 待办 1：补跑 Android 构建验证 PopupDbReader

Task 20 重构了 `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDbReader.kt`（加 schema 版本守卫 + 命名查询 + 去重 `openDb()`），但 **Kotlin 编译未能验证**：`compileDebugKotlin` 依赖 `compileFlutterBuildDebug`，后者因上述 sync 缺包的 Dart 编译错误失败，位于 Kotlin 编译之上游。改动本身已人工审查确认语法正确。

解除条件满足后：
```bash
cd hibiki/android && ./gradlew.bat :app:assembleRelease
# 期望：BUILD SUCCESSFUL（同时验证 PopupDbReader.kt 编译）
```
注意：`assembleRelease` 历史上还会因 `GeneratedPluginRegistrant.java` 缺 `IntegrationTestPlugin` 失败，这是另一个预先存在问题，需一并确认。

---

## 待办 2：收敛残留 Platform.is* 检查（计划目标 ≤15，当前 32）

Task 19 指标：业务逻辑中残留 `Platform.is*` 共 **32 处**。下面按归属分类。行号为大致位置（并发编辑会偏移），以"文件 + 检查语义"为准。

### 2a. sync 模块（5 处）— 由 sync 模块负责，落地时一并改

| 文件 | 检查 | 建议替换 |
|------|------|----------|
| `lib/src/sync/google_drive_auth.dart` | `Platform.isAndroid \|\| Platform.isIOS` | `isMobilePlatform` |
| `lib/src/sync/sync_settings_schema.dart` (×3) | `Platform.isAndroid \|\| Platform.isIOS` | `isMobilePlatform` |

### 2b. 可机械替换为现有 platform_utils getter（优先做）

`platform_utils.dart` 已有：`isMobilePlatform` / `isAndroidPlatform` / `isIOSPlatform` / `isDesktopPlatform` / `isWindowsPlatform` / `supportsNativeAudio` / `supportsFloatingOverlay`。

| 文件 | 检查 | 替换 |
|------|------|------|
| `lib/src/models/theme_notifier.dart` | `!isAndroid && !isIOS` | `!isMobilePlatform` |
| `lib/src/models/anki_integration.dart` (×3) | `Platform.isAndroid` 系列 | `isAndroidPlatform`（或下沉到 Anki 服务） |
| `lib/src/pages/implementations/anki_settings_page.dart` | `!Platform.isAndroid` | `!isAndroidPlatform` |
| `lib/src/pages/implementations/audio_recorder_page.dart` | `isAndroid \|\| isIOS \|\| isMacOS` | `supportsNativeAudio` |
| `lib/src/pages/implementations/dictionary_dialog_page.dart` | `isAndroid\|\|isIOS`(×2) / `!isIOS` / `!isAndroid` | `isMobilePlatform` / `!isIOSPlatform` / `!isAndroidPlatform` |
| `lib/src/pages/implementations/miscellaneous_settings_page.dart` (×2) | `!isAndroid` / `isAndroid` | `!isAndroidPlatform` / `isAndroidPlatform` |
| `lib/src/pages/implementations/reader_hibiki_page.dart` | `Platform.isWindows && ...` | `isWindowsPlatform` |
| `lib/src/settings/settings_schema.dart` (×3) | `visible: (_) => Platform.isAndroid` | `isAndroidPlatform` |
| `lib/src/utils/misc/hibiki_toast.dart` | `isAndroid \|\| isIOS` | `isMobilePlatform` |
| `lib/src/utils/misc/update_checker.dart` | `!Platform.isAndroid` | `!isAndroidPlatform` |
| `lib/src/utils/misc/tts_channel.dart` | `Platform.isAndroid`（支持标志） | `isAndroidPlatform`（或新增 `supportsTts` getter） |
| `lib/src/media/audiobook/floating_lyric_channel.dart` | `platformOverride ?? Platform.isAndroid` | `platformOverride ?? supportsFloatingOverlay` |

### 2c. 需要先补 getter 或下沉到服务（中等改动）

| 文件 | 检查 | 说明 |
|------|------|------|
| `lib/src/utils/misc/webview_asset_url.dart` | `isAndroid` / `isIOS \|\| isMacOS` | `platform_utils` 缺 macOS getter；先加 `isMacOSPlatform`（或 `isApplePlatform`）再替换 |
| `lib/src/utils/components/hibiki_text_selection_controls.dart` (×2) | `Platform.isIOS ? cupertino : material` | 合法的平台特定 UI；为一致性可改 `isIOSPlatform`，非必须 |

### 2d. 合法的平台特定逻辑，建议下沉而非简单替换（较大改动，低优先级）

| 文件 | 检查 | 说明 |
|------|------|------|
| `lib/src/pages/implementations/custom_fonts_page.dart` (×4) | Windows/macOS/Linux 各自字体目录分支 | 每个 OS 的目录逻辑不同，不能简化成 bool getter。更好的做法是新增 `PlatformDirectoryService.getFontDirectories()`，由各平台实现提供 |

> 注：2b/2c 完成后业务逻辑残留应降到约 4-5 处（仅 2d 的 custom_fonts_page 与 text_selection_controls），满足计划 ≤15 目标。

---

## 待办 3：核实并发会话混入的提交（提交卫生）

本次执行期间，并发会话遗留在工作区的 shortcut 改动一度被卷入提交。已剥离 `app_model.dart` 中无关 hunk，但提交 `be04edb4c` 仍混入了对方的 `hibiki/lib/src/shortcuts/shortcut_preferences.dart` 与 `hibiki/test/shortcuts/shortcut_registry_test.dart`（文件已被提交保存、未丢失）。

待办：确认这两个文件的最终归属，避免与并发会话后续提交冲突。若对方已另行提交相同改动，需处理重复/合并。
