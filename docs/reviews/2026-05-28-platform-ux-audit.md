# Hibiki 全平台使用问题与体验审计报告

**日期**: 2026-05-28
**审查方式**: 4 路 Opus 并行代码审查（Windows 平台 / Android 平台 / UX 体验 / 数据流状态）
**分支**: develop

---

## 总览

| 审查维度 | Critical | High | Medium | Low | 合计 |
|----------|----------|------|--------|-----|------|
| Windows 平台 | 1 | 5 | 7 | 4 | 17 |
| Android 平台 | 1 | 3 | 4 | 3 | 11 |
| UX 体验 | 0 | 2 | 6 | 6 | 14 |
| 数据流/状态 | 1 | 4 | 6 | 5 | 16 |
| **合计** | **3** | **14** | **23** | **18** | **58** |

---

## Critical（必须立即修复）

### HBK-ANDROID-001: NowPlayingListenerService 幽灵服务声明 — 运行时必崩

- **severity**: Critical
- **status**: open
- **文件**: `hibiki/android/app/src/main/AndroidManifest.xml:124-131`
- **根因**: Manifest 声明了 `com.gomes.nowplaying.NowPlayingListenerService`（NotificationListenerService），但 `nowplaying` 包已从 `pubspec.yaml` 移除，该类在构建中不存在。
- **影响**: 用户在系统 "通知管理权限" 中启用 Hibiki 的通知监听时，系统持续绑定不存在的类 → `ClassNotFoundException` → 错误日志 / ANR。
- **修复建议**: 删除这 6 行 service 声明。
- **验证方式**: `grep -n "NowPlayingListenerService" hibiki/android/app/src/main/AndroidManifest.xml` 应无结果。

### HBK-WIN-001: `window.devicePixelRatio` 使用已弃用顶层对象 — 多显示器 WebView 渲染错位

- **severity**: Critical
- **status**: open
- **文件**: `packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart:418, 428`
- **根因**: 直接使用 `dart:ui` 的顶层 `window.devicePixelRatio`，Flutter 3.10+ 已弃用，多窗口/多显示器场景返回错误缩放因子。
- **影响**: 多显示器或不同 DPI 的 Windows 环境中，WebView 内容模糊或点击位置偏移。
- **修复建议**: 替换为 `View.of(context).devicePixelRatio` 或 `MediaQuery.devicePixelRatioOf(context)`，需将 `BuildContext` 传入 `_reportSurfaceSize()` 和 `_reportWidgetPosition()`。
- **验证方式**: 在不同 DPI 显示器间拖动窗口，WebView 内容应清晰且点击精准。

### HBK-AUDIT-015: 数据库降级时 DROP ALL + createAll() — 用户全部数据丢失无 UI 警告

- **severity**: Critical (设计决策)
- **status**: open
- **文件**: `packages/hibiki_core/lib/src/database/database.dart:122-145`
- **根因**: 检测到 `from > to`（降级安装）时，备份 DB 后 DROP 所有表并重建。用户的书籍、阅读位置、统计、书签、词典配置全部丢失。备份为 `.bak.N` 后缀文件，用户无法自行恢复。
- **影响**: 用户从测试版回退到稳定版时所有数据丢失。
- **修复建议**: 至少在 UI 上弹出警告对话框告知用户数据将被重置；考虑保留可恢复路径。
- **验证方式**: 安装高版本后降级安装低版本，应有明确警告。

---

## High（强烈建议尽快修复）

### HBK-ANDROID-002: PopupDictActivity 暗色模式检测用错偏好键

- **severity**: High
- **status**: open
- **文件**: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDbReader.kt:167`
- **根因**: 读取 `prefs["theme_mode"]`，但 Dart 侧 `ThemeNotifier` 存的键是 `brightness_mode`。结果 `isDarkMode` 永远为 false。
- **影响**: 暗色模式下弹窗词典仍显示刺眼白色。
- **修复建议**: 改为 `prefs["brightness_mode"]`，空字符串时用 `Configuration.UI_MODE_NIGHT_MASK` 检测系统暗色。
- **验证方式**: 暗色模式下从其他 App 选中文字触发弹窗，应为暗色主题。

### HBK-ANDROID-003: 缺少 POST_NOTIFICATIONS 权限声明

- **severity**: High
- **status**: open
- **文件**: `hibiki/android/app/src/main/AndroidManifest.xml`
- **根因**: `targetSdk 35` 但未声明 `android.permission.POST_NOTIFICATIONS`。Android 13+ 前台服务通知被静默压制。
- **影响**: 悬浮词典/歌词服务通知不显示，用户无法通过通知控制服务。
- **修复建议**: 添加权限声明 + Dart 侧运行时请求。
- **验证方式**: Android 13+ 设备上启动前台服务，通知栏应显示通知。

### HBK-ANDROID-011: PopupDictActivity 系统暗色跟随完全不工作

- **severity**: High
- **status**: open
- **文件**: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDbReader.kt:167`
- **根因**: 与 002 相关。`brightness_mode` 为空（跟随系统）时，PopupDictActivity 在独立 `:popup` 进程中无法访问 Flutter 引擎状态，需 native 侧独立检测。
- **影响**: 跟随系统模式下弹窗永远亮色。
- **修复建议**: 空字符串时用 `context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK` 检测。

### HBK-WIN-002: TTS 在 Windows 上完全不可用 — 静默失败

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/utils/misc/tts_channel.dart:14`
- **根因**: `_isSupported = Platform.isAndroid` 硬编码。所有 TTS 方法在 Windows 上直接 return 空值/false，无 UI 反馈。
- **影响**: Windows 用户点击发音按钮完全无反应。日语学习者听发音是核心需求。
- **修复建议**: 集成 Windows TTS 或至少隐藏/禁用不可用按钮并提示。

### HBK-WIN-003: 录音功能 (Anki 卡片) Windows 上静默退出

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/creator/enhancements/audio_recorder_enhancement.dart:42`
- **根因**: `if (!Platform.isAndroid) return;`
- **影响**: Windows 用户点击录音无反应无提示。
- **修复建议**: 按平台隐藏不可用的 enhancement 项或提供替代。

### HBK-WIN-004: 相机增强 Windows 上静默退出

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/creator/enhancements/camera_enhancement.dart:40`
- **根因**: `if (!Platform.isAndroid && !Platform.isIOS) return;`
- **影响**: 用户点击拍照创建 Anki 图片无反应。
- **修复建议**: 按平台隐藏或用 WebCam API 替代。

### HBK-WIN-005: WebView 预热被跳过 — 首次阅读器冷启动白屏

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/main.dart:159`
- **根因**: WebView2 预热仅移动端执行，注释说明桌面端可能崩溃。但没有延迟预热逻辑。
- **影响**: 首次打开 EPUB 白屏 500-1500ms。
- **修复建议**: Flutter view attach 后的 post-frame callback 中异步预热。

### HBK-WIN-006: "从文件夹导入词典" 仅 Android 可见

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:45`
- **根因**: `if (Platform.isAndroid)` 限制。
- **影响**: Windows 用户只能逐文件导入词典。
- **修复建议**: 改为 `if (!Platform.isIOS)` 或移除限制。

### HBK-AUDIT-001: fire-and-forget void async — DB 写入异常被静默吞掉

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/models/dictionary_repository.dart:120, 132, 256`; `hibiki/lib/src/models/media_history_repository.dart:88, 102, 137, 169`
- **根因**: 多个 `void ... async {}` 方法，调用方无法 await 或捕获异常。DB 写入失败时内存缓存已更新但磁盘未持久化。
- **影响**: 词典顺序、搜索历史等看似保存成功但重启后回退。
- **修复建议**: 返回类型改 `Future<void>`，调用方 await 或 catchError 显示错误。

### HBK-AUDIT-003: shutdown() 是 void async — DB 可能未关闭就 exit

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:2311-2318`
- **根因**: `void` 返回但标记 `async`，`exit(0)` 可能在 WAL checkpoint 完成前终止进程。
- **影响**: 阅读位置或统计数据可能丢失。
- **修复建议**: 改为 `Future<void>`，close 后执行 `PRAGMA wal_checkpoint(TRUNCATE)` 再 exit。

### HBK-AUDIT-005: EPUB 导入 rename 失败后 DB-磁盘状态不一致

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/epub/epub_importer.dart:84-101`
- **根因**: rename 成功后才 update DB 路径。如果 rename 成功但 update 失败，DB 指向旧路径（已被 rename 走了）。
- **影响**: 低存储或跨卷时书籍导入成功但无法打开。
- **修复建议**: rename + update 包在事务中；或不 rename，直接用 extractDir。

### HBK-AUDIT-008: 阅读器缺少 didChangeAppLifecycleState — 后台杀进程丢位置

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:72-73`
- **根因**: mixin 了 `WidgetsBindingObserver` 但只重写 `didChangeMetrics()`，未重写 `didChangeAppLifecycleState()`。后台杀进程时 `dispose()` 不会被调用。
- **影响**: 后台杀进程后阅读位置回退 1-2 次翻页。
- **修复建议**: 添加 `didChangeAppLifecycleState`，在 `paused`/`inactive` 时调用 `_flushPosition()` 和 `_flushReadingStats()`。

### UX-002: 书籍文件丢失时阅读器静默 pop()

- **severity**: High
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:232-235`
- **根因**: EPUB 文件被外部删除后只 `debugPrint` 日志 + `Navigator.pop()`。
- **影响**: 用户点击书籍后什么都没发生就回到书架，完全不知原因。
- **修复建议**: pop 前显示 Toast "书籍文件未找到" 或弹对话框提供"从书架移除"选项。

### UX-007: 无障碍支持几乎空白

- **severity**: High
- **status**: open
- **文件**: 全局 `hibiki/lib/src/pages/`
- **根因**: 整个 pages 目录仅 1 处 `Semantics` 使用。书架卡片、阅读器按钮、进度条等核心交互元素无语义标注。
- **影响**: TalkBack/VoiceOver 用户无法有效使用应用。
- **修复建议**: 分阶段推进，优先处理书架和阅读器核心路径。

---

## Medium

### HBK-ANDROID-009: provider_paths.xml root-path 暴露整个文件系统

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/android/app/src/main/res/xml/provider_paths.xml:16-18`
- **根因**: `<root-path name="root" path="." />` 将设备整个文件系统暴露给 FileProvider URI。
- **影响**: 安全风险；Google Play 审核可能标记。
- **修复建议**: 移除 root-path，用精确的路径声明覆盖合法场景。

### HBK-ANDROID-010: FloatingLyricService foregroundServiceType 声明为 mediaPlayback 但不播媒体

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/android/app/src/main/AndroidManifest.xml:140-141`
- **根因**: 纯 UI 悬浮歌词窗口声明 `mediaPlayback` 类型。
- **影响**: Android 14+ Play 审核风险。
- **修复建议**: 改为 `specialUse` + 添加 `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`。

### HBK-ANDROID-005: enableOnBackInvokedCallback=false — 不支持预测性返回手势

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/android/app/src/main/AndroidManifest.xml:19`
- **影响**: Android 15+ 无预测性返回动画；Android 16 升级 targetSdk 后可能成阻断问题。
- **修复建议**: 设为 true 并验证 WebView 内返回导航。

### HBK-ANDROID-004: 孤立的 accessibilityservice.xml

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/android/app/src/main/res/xml/accessibilityservice.xml`
- **根因**: Manifest 引用的是 `hibiki_dict_accessibility.xml`，此文件未被引用但请求过度权限。
- **影响**: 维护混淆；误引用时 Play 审核拒绝。
- **修复建议**: 删除。

### HBK-AUDIT-010: 弹窗词典与主应用同时打开 DB 无 busy_timeout

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:1175-1263`
- **根因**: PopupDictActivity 在独立 `:popup` 进程中创建新 DB 实例，无 `busy_timeout` PRAGMA。
- **影响**: 并发写入时可能 `SQLITE_BUSY`。
- **修复建议**: setup 回调中添加 `db.execute('PRAGMA busy_timeout = 5000');`。

### HBK-AUDIT-006: Anki 设置用 SharedPreferences 而非 Drift — Profile 不跟随

- **severity**: Medium
- **status**: open
- **文件**: `packages/hibiki_anki/lib/src/base_anki_repository.dart:14-29`
- **根因**: Anki 配置走 SharedPreferences，其他偏好走 Drift。
- **影响**: Profile 切换不影响 Anki 设置；数据库备份恢复后 Anki 设置丢失。
- **修复建议**: 迁移到 Drift preferences 表。

### HBK-AUDIT-007: HoshiDicts.lookup() 主 isolate 同步 FFI — 大词典可能卡 UI

- **severity**: Medium
- **status**: open
- **文件**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart:387-433`
- **根因**: lookup/query/lookupPopupJson 在主 isolate 同步调用 C++ FFI。
- **影响**: 低端设备划词查词可能短暂 UI 卡顿。
- **修复建议**: 包装在 `Isolate.run()` 或后台 isolate 常驻。

### HBK-AUDIT-011: deleteEpubBook() 不清理 audiobooks/audio_cues

- **severity**: Medium
- **status**: open
- **文件**: `packages/hibiki_core/lib/src/database/database.dart:725-731`
- **根因**: 事务清理了 readerPositions/bookmarks/srtBooks，但漏了 audiobooks/audio_cues。
- **影响**: 删书后音频数据残留，长期累积使 DB 膨胀。
- **修复建议**: 通过 bookUid 规则也清理音频表。

### HBK-AUDIT-016: 大目录导入词典时全内存 ZIP — 可能 OOM

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/dictionary_import_manager.dart:123-139`
- **根因**: 整个目录 `readAsBytesSync` 到 Dart 堆再 ZIP 编码，峰值内存达目录 2-3 倍。
- **影响**: 导入大辞泉等大型解压词典时 OOM。
- **修复建议**: 直接传目录路径给 C++ FFI，或用流式压缩。

### HBK-AUDIT-002: Future.wait 并发填充词典路径列表 — 搜索优先级不确定

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:438-466`
- **根因**: 并发回调向同一 List 执行 `.add()`，完成顺序不可预测。
- **影响**: 词典搜索结果顺序每次启动可能不同。
- **修复建议**: 按原 dictionaries 顺序排序后传给 initializeTyped。

### HBK-AUDIT-004: ReaderPositions.ttuBookId 无外键约束

- **severity**: Medium
- **status**: open
- **文件**: `packages/hibiki_core/lib/src/database/tables.dart:103-110`
- **根因**: 只有 `unique()` 无 `.references()` + cascade。Bookmarks 表正确声明了。
- **影响**: 孤儿记录占空间（历史上已发生过，迁移 v12 做过清理）。
- **修复建议**: 下次 schema 升级时加外键。

### HBK-WIN-007: SystemChrome.immersiveSticky Windows 无效

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:1847`
- **影响**: 阅读器无沉浸模式，标题栏/任务栏占阅读空间。
- **修复建议**: Windows 上用 `window_manager` 的 `setFullScreen` 或 `setTitleBarStyle(hidden)`。

### HBK-WIN-008: 未设置窗口最小尺寸

- **severity**: Medium
- **status**: open
- **影响**: 极端缩小时 UI 布局溢出。
- **修复建议**: 设最小 400x600。

### HBK-WIN-009: 自动更新检查 Windows 完全禁用

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/utils/misc/update_checker.dart:69`
- **影响**: Windows 用户永远不知道有新版本。
- **修复建议**: 检查 GitHub Release 并提示下载链接。

### HBK-WIN-010: 文件选择器推荐目录 Windows 为空

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:2182-2202`
- **影响**: 首次使用需手动导航。
- **修复建议**: 添加 Documents/Downloads 默认推荐。

### UX-001: 4 处仍用废弃 WillPopScope — Android 14+ 返回手势异常

- **severity**: Medium
- **status**: open
- **文件**: `loading_page.dart:18`, `dictionary_dialog_import_page.dart:40`, `dictionary_dialog_delete_page.dart:29`, `placeholder_source_page.dart:20`
- **修复建议**: 替换为 `PopScope(canPop: false, ...)`。

### UX-003: EPUB 解析失败降级路径无用户通知

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:243-251`
- **影响**: 用户看到格式错乱内容以为是 bug 而非 EPUB 问题。
- **修复建议**: 走 fallback 时显示 Toast 提示。

### UX-004: 初始化失败页面无恢复操作

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/main.dart:292-343`
- **影响**: 用户被完全卡住只能强杀应用。
- **修复建议**: 添加 "重试" 和 "复制错误信息" 按钮。

### UX-006: 书架空状态缺导入引导

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:972-979`
- **影响**: 新用户不知如何添加书籍。
- **修复建议**: 添加 "导入 EPUB" 按钮（词典页面已有类似设计）。

### UX-008: 词典导入/删除对话框不可取消

- **severity**: Medium
- **status**: open
- **文件**: `dictionary_dialog_import_page.dart:40-41`, `dictionary_dialog_delete_page.dart:29-30`
- **影响**: 大词典导入可能数分钟，用户被迫等待无法取消。
- **修复建议**: 超时后显示取消按钮。

### UX-012: 词典导入错误仅 Toast 闪过

- **severity**: Medium
- **status**: open
- **文件**: `hibiki/lib/src/models/dictionary_import_manager.dart:112-117`
- **影响**: 批量导入时 Toast 互相覆盖，用户不知哪些成功哪些失败。
- **修复建议**: 批量导入完成后显示汇总对话框。

---

## Low

### HBK-ANDROID-006: enableJetifier 仍为 true — 不必要的构建开销

- **severity**: Low
- **status**: open
- **文件**: `hibiki/android/gradle.properties:5`
- **修复建议**: 设为 false 试构建。

### HBK-ANDROID-007: isAppRunning 永远为 false — 死代码

- **severity**: Low
- **status**: open
- **文件**: `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java:106, 118-121`
- **修复建议**: 删除或修正逻辑。

### HBK-ANDROID-008: WRITE_EXTERNAL_STORAGE + requestLegacyExternalStorage 冗余

- **severity**: Low
- **status**: open
- **文件**: `hibiki/android/app/src/main/AndroidManifest.xml:4, 18`
- **修复建议**: 移除或添加 `maxSdkVersion="28"`。

### HBK-WIN-011: .nomedia 在 Windows 上无意义仍创建

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:890, 916`
- **修复建议**: `if (Platform.isAndroid)` 条件包裹。

### HBK-WIN-012: FlutterLogs 仅移动端初始化 — Windows 无文件日志

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/main.dart:130`
- **修复建议**: Windows 上用 `logging` 包或直接写文件。

### HBK-WIN-013: 应用图标设置页在 Windows 上渲染空白

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart:126`
- **修复建议**: 添加 "此平台不适用" 提示。

### HBK-WIN-014: exit(0) 强制退出 — 可能丢数据

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/models/app_model.dart:2317`
- **修复建议**: 使用 `SystemNavigator.pop()` 或 `windowManager.close()`。

### HBK-WIN-015: 悬浮词典 Windows 不可用但设置仍可切换

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/media/floating_dict_channel.dart`
- **修复建议**: 按平台隐藏设置开关。

### HBK-AUDIT-009: LruCache 返回可变引用 — 缓存污染风险

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/models/dictionary_repository.dart:20-21`
- **影响**: 缓存驱逐后重新搜索，滚动位置重置。

### HBK-AUDIT-012: PrefCodec defaultValue 隐式写入 — preferences 表膨胀

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/models/preferences_repository.dart:30-37`
- **影响**: 大量从未修改的默认值占据 preferences 表。

### HBK-AUDIT-013: _flushReadingStats 跨午夜统计不准确

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2948-2970`
- **影响**: 跨午夜阅读时间全部计入最后 flush 时的小时。

### HBK-AUDIT-014: HoshiDicts 单例 initialize 非原子 — 架构脆弱

- **severity**: Low
- **status**: open
- **文件**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart:226-258`
- **影响**: 当前安全，但未来加 await 可能导致 native crash。

### UX-005: 初始化过程加载页完全空白

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/main.dart:345-361`
- **影响**: 冷启动 2-5 秒空白屏幕。
- **修复建议**: 添加简单 CircularProgressIndicator。

### UX-009: 阅读器 8 秒超时强制移除覆盖层无反馈

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1714-1723`
- **影响**: 超时后可能显示不完整页面。

### UX-010: shouldPlaceholderBeShown 硬编码 true — 死代码

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/history_reader_page.dart:40`
- **修复建议**: 修正逻辑或标记 `@mustBeOverridden`。

### UX-011: 阅读器底部工具栏无音频时功能过少

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:3293-3336`
- **影响**: 目录/书签/搜索被深埋在设置面板里。

### UX-014: 阅读器主题颜色硬编码 — 高对比度模式不响应

- **severity**: Low
- **status**: open
- **文件**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:3845-3877`
- **影响**: 视力较弱用户在 dark-theme 下可能看不清。

---

## 正面发现（设计优良）

- **FFI 构建配置完善**: hoshidicts C++ 词典引擎 Windows/Android 构建完整配置
- **WebView2 错误恢复**: 阅读器正确处理 `hoshi.local` 域名拦截的伪错误
- **桌面自适应布局**: HomePage 使用 LayoutBuilder + WindowSizeClass 正确渲染 NavigationRail
- **键盘导航**: 阅读器支持方向键/PageUp/PageDown/Space 翻页，HomePage 支持 Ctrl+1/2/3
- **Google Drive 桌面认证**: Windows 上正确使用 OAuth 浏览器回调流程
- **Anki 连接**: 非 Android 平台正确使用 AnkiConnectRepository 替代
- **WebView 资源路径**: 正确处理 Windows 的 `data/flutter_assets/` 路径
- **UTF-8 编译选项**: CMakeLists.txt 添加 `/utf-8` 防止 CJK 系统警告

---

## 推荐修复优先级

### 第一批（Critical + 高频影响 High，预估 2-3 小时）
1. 删除 `NowPlayingListenerService` 幽灵声明（1 行删除）
2. 修复 PopupDbReader 偏好键 + 系统暗色跟随
3. 添加 `POST_NOTIFICATIONS` 权限
4. 阅读器添加 `didChangeAppLifecycleState`（~10 行）
5. `shutdown()` 改 `Future<void>` 确保 DB 关闭

### 第二批（UX 体验 + Windows 可用性，预估 3-4 小时）
6. 不可用功能在 Windows 上隐藏或提示（TTS/录音/相机/悬浮词典）
7. 书籍文件丢失时显示 Toast 而非静默退出
8. `WillPopScope` → `PopScope` 迁移（4 处）
9. `provider_paths.xml` 移除 `root-path`
10. `FloatingLyricService` foregroundServiceType 改 `specialUse`

### 第三批（数据可靠性，预估 4-6 小时）
11. fire-and-forget async 方法改 `Future<void>`
12. EPUB 导入 rename 事务化
13. `deleteEpubBook()` 补充音频数据清理
14. DB busy_timeout 设置
15. Anki 设置迁移到 Drift

---

## Next Scope

- 阅读器 WebView JS 分页引擎的边界情况和性能
- 有声书音频同步精度和 UI 交互
- 网络请求（Google Drive 同步、更新检查）的错误恢复
- 多 Profile 切换的数据隔离完整性

---

## 修复记录 (2026-05-28)

### 已修复（46 文件，575 行增，111 行删）

| ID | 状态 | 修复内容 |
|----|------|---------|
| HBK-ANDROID-001 | **fixed** | 删除 NowPlayingListenerService 幽灵服务声明 |
| HBK-ANDROID-002+011 | **fixed** | PopupDbReader 暗色模式 `theme_mode` → `brightness_mode` + 系统暗色跟随 |
| HBK-ANDROID-003 | **fixed** | 添加 `POST_NOTIFICATIONS` 权限 |
| HBK-ANDROID-004 | **fixed** | 删除孤立 `accessibilityservice.xml` |
| HBK-ANDROID-005 | **fixed** | `enableOnBackInvokedCallback` → `true` |
| HBK-ANDROID-006 | **fixed** | `enableJetifier` → `false` |
| HBK-ANDROID-007 | **fixed** | 删除 `isAppRunning` 死代码 |
| HBK-ANDROID-008 | **fixed** | 移除冗余 `WRITE_EXTERNAL_STORAGE` + `requestLegacyExternalStorage` |
| HBK-ANDROID-009 | **fixed** | `provider_paths.xml` 移除 `root-path` |
| HBK-ANDROID-010 | **fixed** | FloatingLyricService `mediaPlayback` → `specialUse` |
| HBK-WIN-001 | **fixed** | `window.devicePixelRatio` → `View.of(context).devicePixelRatio` |
| HBK-WIN-002 | **fixed** | TTS 添加 `isSupported` 静态 getter |
| HBK-WIN-003 | **fixed** | AudioRecorderEnhancement 添加 `isAvailable` + 按平台过滤 |
| HBK-WIN-004 | **fixed** | CameraEnhancement 添加 `isAvailable` + 按平台过滤 |
| HBK-WIN-006 | **fixed** | 词典文件夹导入 `Platform.isAndroid` → `!Platform.isIOS` |
| HBK-WIN-010 | **fixed** | Windows 文件选择器添加 Documents/Downloads 默认目录 |
| HBK-WIN-011 | **fixed** | `.nomedia` 创建包裹 `if (Platform.isAndroid)` |
| HBK-WIN-013 | **fixed** | 图标设置页非 Android 显示 "不支持" 提示 |
| HBK-WIN-015 | **fixed** | 悬浮歌词设置按平台隐藏 |
| HBK-AUDIT-001 | **fixed** | 8 个 fire-and-forget `void async` → `Future<void>` |
| HBK-AUDIT-002 | **fixed** | 词典路径 Future.wait → 按原顺序排序 |
| HBK-AUDIT-003 | **fixed** | `shutdown()` → `Future<void>` |
| HBK-AUDIT-008 | **fixed** | 阅读器添加 `didChangeAppLifecycleState` |
| HBK-AUDIT-010 | **fixed** | DB setup 添加 `PRAGMA busy_timeout = 5000` |
| HBK-AUDIT-011 | **fixed** | `deleteEpubBook` 补充 audiobooks/audioCues 清理 |
| HBK-AUDIT-012 | **fixed** | `getPref` 移除 defaultValue 隐式写入 |
| HBK-AUDIT-015 | **partial** | 属设计决策，需 UI 警告层面修复（已记录） |
| UX-001 | **fixed** | 4 处 `WillPopScope` → `PopScope` |
| UX-002 | **fixed** | 书籍文件丢失时显示 Toast |
| UX-003 | **fixed** | EPUB 解析降级时显示 Toast |
| UX-004 | **fixed** | 初始化失败页面添加 重试 + 复制错误 按钮 |
| UX-005 | **fixed** | 初始化加载页添加 CircularProgressIndicator |
| UX-006 | **fixed** | 书架空状态添加导入按钮 |
| UX-009 | **fixed** | 阅读器 8 秒超时显示 Toast 提示 |
| UX-010 | **fixed** | `shouldPlaceholderBeShown` 改为基于实际数据判断 |
| UX-012 | **fixed** | 词典批量导入失败改为汇总提示 |

### 未修复（需架构变更或外部依赖）

| ID | 原因 |
|----|------|
| HBK-AUDIT-004 | 需 schema version 升级（外键约束变更需迁移） |
| HBK-AUDIT-005 | EPUB 导入 rename 事务化需重构导入流程 |
| HBK-AUDIT-006 | Anki SharedPreferences → Drift 迁移涉及跨 package 改动 |
| HBK-AUDIT-007 | HoshiDicts FFI isolate 化需重新设计 native handle 传递 |
| HBK-AUDIT-013 | 跨午夜统计需重构 hourly log 写入逻辑 |
| HBK-AUDIT-014 | 架构层面脆弱性，当前安全 |
| HBK-AUDIT-016 | 目录导入 ZIP 内存问题需 C++ FFI 支持目录直接导入 |
| HBK-WIN-005 | WebView2 延迟预热需调研桌面端崩溃根因 |
| HBK-WIN-007 | Windows 沉浸模式需添加 `window_manager` 依赖 |
| HBK-WIN-008 | 窗口最小尺寸需 native 代码或 `window_manager` |
| HBK-WIN-009 | Windows 更新检查需完整实现 |
| HBK-WIN-012 | Windows 文件日志需选型 |
| HBK-WIN-014 | `exit(0)` 已部分修复（shutdown 改 Future），完整修复需 windowManager |
| UX-007 | 无障碍支持需系统性分阶段推进 |
| UX-008 | 词典导入取消需要中断 FFI 调用支持 |
| UX-011 | 阅读器工具栏改版属 UX 设计决策 |
| UX-014 | 主题颜色配置化属功能增强 |

### 验证结果

- `flutter analyze`: 0 errors, 0 warnings (14 pre-existing info)
- `assembleRelease`: BUILD SUCCESSFUL
- WebView fork analyze: 0 errors
- hibiki_core analyze: No issues found
- 新增 i18n keys: 7 个（通过 i18n_sync.dart 同步到 17 种语言）
