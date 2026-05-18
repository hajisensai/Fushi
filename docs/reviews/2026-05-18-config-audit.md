# 2026-05-18 配置项全量审查与修复报告

## Scope

本轮检查范围：
- 所有偏好设置读写路径（`app_model.dart` `_getPref`/`_setPref` 体系）
- `ReaderSettings` 缓存与 Profile 系统交互
- `setBlurOptions` 持久化完整性
- 所有 setter 方法的 `notifyListeners()` 调用一致性
- 文档注释准确性
- Windows 平台构建 + 724 个单元测试
- 主题、字典、播放器、模糊窗口、阅读器、Profile 系统的 UI 绑定

## Findings

### HBK-AUDIT-001: ReaderSettings 缓存在 Profile 切换后不刷新

- **severity**: HIGH
- **status**: FIXED
- **file**: `hibiki/lib/src/reader/reader_settings.dart`, `hibiki/lib/src/profile/profile_view_model.dart`
- **根因**: `ReaderSettings._cache` 在构造时通过 `_loadAll()` 加载一次，之后没有公开的刷新方法。Profile 切换时 `onApplied()` 回调只刷新了 `MediaSource._preferences`（通过 `refreshPreferencesFromDb()`）和 `AppModel._prefCache`（通过 `refreshPrefCache()`），但 `ReaderSettings._cache` 保持过时状态。
- **影响**: Profile 切换后，阅读器的 fontSize、lineHeight、writingMode、margins 等所有通过 `ReaderSettings` 读取的设置不会更新，直到 app 重启。
- **修复**: 在 `ReaderSettings` 中添加 `refreshFromDb()` 公开方法，在 `profile_view_model.dart` 的 `onApplied` 回调中调用 `ReaderHoshiSource.readerSettings?.refreshFromDb()`。
- **验证**: flutter analyze 通过，724 测试通过，Windows build 成功。

### HBK-AUDIT-002: 20+ setter 方法缺少 notifyListeners()

- **severity**: MEDIUM-HIGH
- **status**: FIXED
- **file**: `hibiki/lib/src/models/app_model.dart`
- **根因**: AppModel 继承 ChangeNotifier，UI 通过 `ref.watch(appProvider)` 订阅变化。多个 setter 只更新内存缓存和数据库，但没有调用 `notifyListeners()`，导致 UI 不重建。
- **受影响方法**:
  - 播放器: `togglePlayerListeningComprehensionMode`, `togglePlayerOrientationPortrait`, `toggleStretchToFill`, `setPlayerHardwareAcceleration`, `setPlayerBackgroundPlay`, `setShowSubtitlesInNotification`, `setPlayerUseOpenSLES`
  - 字典/搜索: `toggleAutoSearchEnabled`, `setSearchDebounceDelay`, `setDictionaryFontSize`, `setMaximumTerms`, `toggleCollapseDictionaries`, `toggleDeduplicatePitchAccents`, `toggleHarmonicFrequency`, `toggleAutoAddBookNameToTags`
  - 播放器状态: `toggleTranscriptPlayerMode`, `toggleTranscriptOpaque`, `toggleSubtitleTimingsShown`, `setDoubleTapSeekDuration`
  - 音频: `setAudioSources`, `toggleLocalAudio`
- **影响**: 设置变更后，同一次 session 内其他依赖该设置的页面不会及时更新。例如修改字典字体大小后，已打开的字典页面显示旧字体。
- **修复**: 逐个添加 `notifyListeners()` 到所有缺失的 setter。
- **验证**: flutter analyze 通过，724 测试通过。

### HBK-AUDIT-003: setBlurOptions() 10 个 _setPref 调用全部 fire-and-forget

- **severity**: MEDIUM
- **status**: FIXED
- **file**: `hibiki/lib/src/models/app_model.dart:3256`
- **根因**: `setBlurOptions()` 声明为 `void`（非 async），调用 `_setPref()` 时没有 await，10 个异步写入并行执行，任何一个失败都静默丢失。
- **影响**: 模糊窗口配置可能部分持久化——用户看到设置生效但重启后丢失部分值。
- **修复**: 改为 `Future<void> setBlurOptions(...) async`，所有 `_setPref` 加 await，末尾添加 `notifyListeners()`。
- **验证**: flutter analyze 通过。

### HBK-AUDIT-004: 文档注释 copy-paste 错误

- **severity**: LOW
- **status**: FIXED
- **file**: `hibiki/lib/src/models/app_model.dart`
- **问题**: `dictionaryFontSize` getter 和 setter 的 docstring 错误地写成"search debounce delay"（从 `searchDebounceDelay` 复制过来）。`setPlayerUseOpenSLES` 的 docstring 写成"hardware acceleration"。
- **修复**: 修正为准确描述。

## 已确认无问题的区域

### 配置 UI 绑定
- 显示设置页面（13 个控件）: 所有 slider/switch 正确绑定到 ReaderSettings getter/setter ✓
- 自定义主题页面（11 个颜色选择器）: 全部通过 `applyCustomTheme()` 批量调用 ✓
- 字典设置页面（12+ 设置）: 全部正确绑定 ✓
- 阅读器行为设置（11+ 设置）: 全部正确绑定 ✓
- 有声书设置（3 个控件）: 全部正确绑定 ✓
- 更新设置（4 个控件）: 全部已有 notifyListeners() ✓
- 模糊选项对话框: 正确读写 ✓
- Anki 设置: 通过 AnkiViewModel 正确管理 ✓

### Profile 系统
- `snapshotCurrentSettings`: 正确捕获所有非排除的偏好 + Anki 设置 ✓
- `applyProfile`: 事务正确，legacy 分类正确迁移 ✓
- `deleteProfile`: 安全阻止删除最后一个 Profile ✓
- `copyProfile`: 正确深拷贝所有设置 ✓
- `resolveProfileId`: 优先级 book > mediaType > active 正确 ✓

### Windows 平台
- `flutter analyze`: 零问题 ✓
- `flutter build windows`: 成功构建 hibiki.exe ✓
- `flutter test`: 724 测试全部通过 ✓
- 偏好持久化使用 Drift SQLite，跨平台一致 ✓
- 自定义字体路径检测正确处理 Windows 字体目录 ✓
- WebView2 workaround 正确处理 hoshi.local 导航 ✓

### 偏好系统数据结构
- `_getPref` / `_setPref` 类型转换逻辑正确 ✓
- 内存缓存 + DB 持久化双层架构健全 ✓
- Profile 排除列表合理（`active_profile_id`, `first_time_setup`, `current_home_tab_index`, `app_locale`, session-specific keys）✓

### HBK-AUDIT-005: 字典弹窗背景不跟随阅读器主题（三重根因）

- **severity**: HIGH
- **status**: FIXED（兼容层）
- **file**: `hibiki/assets/popup/popup.css`, `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`, `hibiki/lib/src/pages/implementations/dictionary_structured_content_page.dart`
- **根因（三重）**:
  1. **CSS 变量声明但未使用**: `popup.css` 的 `html, body` 设置 `background-color: transparent`，`--background-color` 变量被 JS 注入但从未被 `background-color` 属性引用。
  2. **CSS 变量在 body 上被重复声明**: `html[data-theme="light"], html[data-theme="light"] body` 同时在 `html` 和 `body` 上声明 `--background-color`，阻止 JS 通过 `documentElement.style.setProperty()` 覆盖。
  3. **flutter_inappwebview_windows 0.6.0 `transparentBackground` 逻辑反转**: `in_app_webview.cpp:210` 初始化路径 `if (!settings->transparentBackground)` 把条件写反了——`true` 时跳过设透明（留白色），`false` 时反而设透明。动态更新路径（:1444）逻辑正确。
- **影响**: Windows 上字典弹窗打开时闪白色背景，不跟随阅读器主题。Android 因透明支持正常而部分生效。
- **修复（分层）**:
  1. `popup.css`: `background-color: transparent` → `background-color: var(--background-color, transparent)` — WebView 自己渲染背景色。
  2. `popup.css`: 将 `body` 从 `data-theme` CSS 变量声明选择器中移除，只在 `html` 上声明。
  3. `dictionary_popup_webview.dart`: Windows 上用 `initialData` 内联 HTML（`<html data-theme="..." style="--background-color:...">`），WebView2 解析的第一个字节就有正确背景色，消除 HWND 初始化白闪。Android 保持 `initialUrlRequest` 不变。
  4. `transparentBackground: !Platform.isWindows` — 绕过插件反转 bug。
  5. `dictionary_structured_content_page.dart`: 同样应用 `transparentBackground: !Platform.isWindows`。
- **验证**: flutter analyze 通过，Windows build 成功，用户确认白色闪烁消除。
- **后续清理条件**: fork `flutter_inappwebview_windows` 修复 `in_app_webview.cpp:210` 的 `!` 号后，可以移除 `!Platform.isWindows` hack 和 Windows `initialData` 分支，统一回 `initialUrlRequest`。

### HBK-AUDIT-006: flutter_inappwebview_windows transparentBackground 逻辑反转（外部依赖 bug）

- **severity**: MEDIUM
- **status**: WORKAROUND（待 fork 根治）
- **file**: `flutter_inappwebview_windows-0.6.0/windows/in_app_webview/in_app_webview.cpp:210`
- **根因**: 初始化路径条件取反 `if (!settings->transparentBackground)`，与动态更新路径 `:1444` 的正确逻辑 `newSettings->transparentBackground ? 0 : 255` 不一致。
- **影响**: `transparentBackground: true` 在 Windows 上初始化时不生效，WebView2 默认白色背景。
- **当前绕过**: Dart 侧 `transparentBackground: !Platform.isWindows` 利用反转逻辑达到透明效果。
- **根治方案**: fork `flutter_inappwebview_windows`，修改 `:210` 为 `if (settings->transparentBackground)`（去掉 `!`），或改写为与动态路径一致的 `BYTE alpha = settings->transparentBackground ? 0 : 255` 模式。
- **清理后影响**: 移除所有 `!Platform.isWindows` hack，`transparentBackground: true` 全平台统一。

### HBK-AUDIT-007: 阅读器弹窗遮罩（scrim）始终透明

- **severity**: MEDIUM
- **status**: FIXED
- **file**: `hibiki/lib/src/pages/base_source_page.dart:228`
- **根因**: `buildDictionary()` 里弹窗背后的 `Positioned.fill` GestureDetector 的 `Container` 硬编码 `Colors.transparent`，未读取 `disableDialogScrim` 设置。其他弹窗（`show_app_dialog.dart`、`update_checker.dart`）均读取该设置。
- **影响**: 阅读器字典弹窗弹出时没有半透明遮罩，与全局设置不一致。
- **修复**: 改为 `appModel.disableDialogScrim ? Colors.transparent : Colors.black54`，与其他弹窗一致。
- **验证**: flutter analyze 通过，724 测试通过。

### HBK-AUDIT-005 后续：Windows initialData 内联资源方案

- **severity**: HIGH → FIXED（根治）
- **status**: FIXED
- **file**: `dictionary_popup_webview.dart`, `packages/flutter_inappwebview_windows/`
- **根因链（5 层）**:
  1. **CSS 变量声明但未使用** → 已修复（fd8ea26c）
  2. **CSS body 重复声明** → 已修复（fd8ea26c）
  3. **插件 transparentBackground 逻辑反转** → fork 修复 `in_app_webview.cpp:210`
  4. **NavigateToString() 的 about:blank origin** → 相对 URL 无法解析 → CSS/JS 不加载
  5. **loadData() 忽略 baseUrl** → WebView2 `NavigateToString` 不支持 baseUrl
- **最终方案**:
  - 插件 fork 根治 `transparentBackground` 反转 bug
  - Windows 用 `initialData` 内联 HTML + CSS + JS（从磁盘读取、静态缓存、escape `</script>` / `</style>`）
  - 文件读取失败时自动降级到 `initialUrlRequest`
  - `transparentBackground: true` 全平台统一
  - Android 继续用 `initialUrlRequest` 加载 `popup.html`
- **已通过验证**: flutter analyze 0 issues, 724 tests passed, Windows build 成功
- **待用户验证**: 导入词典后验证弹窗内容正常渲染、无白/黑闪烁

## 已知低优先级观察（非本轮修复范围）

1. **Nullable Color 哨兵值 0**: `customThemeFontColor` 等使用 `0` 表示 null，与 `Color(0x00000000)`（透明黑）冲突。实际影响极低（用户不会选透明黑作为字体色），但技术上不完美。
2. **`async void` 反模式**: 约 30 个 setter 仍然是 `void...async` 而非 `Future<void>`。调用者无法 await 或捕获错误。但在当前架构中，所有调用者都是 fire-and-forget 模式，没有造成实际问题。
3. **`floatingLyricFontSize` getter 未 clamp**: setter 中 clamp(8, 64) 但 getter 直接返回数据库值。如果数据库被手动修改，可能返回超范围值。
4. **popup.html 与 initialData HTML 结构重复**: Windows 用 Dart 内联 HTML，Android 用 `popup.html` 资产文件。两处 HTML 结构需要保持同步。
5. **DictionaryHtmlWidget（定义页面）未使用 initialData**: `dictionary_structured_content_page.dart` 仍用 `initialUrlRequest`，依赖插件 fork 的 `transparentBackground` 修复。闪烁风险低于弹窗（嵌入式 SizedBox 非浮动），但不为零。

## Next Scope

下一轮可审查：
- 阅读器 WebView JS/CSS 注入路径的完整性
- 有声书 SRT 解析与同步时序
- 字典 FFI 导入路径在 Windows 上的 thread stack 行为
