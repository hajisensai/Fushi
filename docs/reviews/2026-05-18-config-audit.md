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

## 已知低优先级观察（非本轮修复范围）

1. **Nullable Color 哨兵值 0**: `customThemeFontColor` 等使用 `0` 表示 null，与 `Color(0x00000000)`（透明黑）冲突。实际影响极低（用户不会选透明黑作为字体色），但技术上不完美。
2. **`async void` 反模式**: 约 30 个 setter 仍然是 `void...async` 而非 `Future<void>`。调用者无法 await 或捕获错误。但在当前架构中，所有调用者都是 fire-and-forget 模式，没有造成实际问题。
3. **`floatingLyricFontSize` getter 未 clamp**: setter 中 clamp(8, 64) 但 getter 直接返回数据库值。如果数据库被手动修改，可能返回超范围值。

## Next Scope

下一轮可审查：
- 阅读器 WebView JS/CSS 注入路径的完整性
- 有声书 SRT 解析与同步时序
- 字典 FFI 导入路径在 Windows 上的 thread stack 行为
