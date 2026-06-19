[根目录](../CLAUDE.md) > **hibiki** (Flutter app)

# hibiki -- 主应用模块

## 模块职责

Hibiki 的 Flutter 多平台主应用：日语 EPUB 阅读器，集成划词查词、有声书同步、Anki 卡片创建、阅读统计。基于 Flutter 跨平台框架，Android 走 Material Design 3 / iOS 走 Cupertino 平台自适应 UI，并通过 fork 的 `flutter_inappwebview_windows` 支持 Windows 桌面端。

## 入口与启动

- **主入口**：`lib/main.dart` -- `main()` 函数，启动流程：
  1. `WidgetsFlutterBinding.ensureInitialized()`
  2. 系统 UI 配置（edge-to-edge、方向锁定、splash 颜色获取）
  3. 创建 `ProviderContainer`，立即 `runApp(HoshiReaderApp())`
  4. 初始化错误日志服务（`ErrorLogService` / `DebugLogService`）
  5. 初始化文件日志（`FlutterLogs`，仅移动端）
  6. `HoshiDicts.preloadTransforms()` 预加载词典变换表
  7. `appModel.initialise()` 完成后 `isInitialised=true`，从 `LoadingPage` 跳转到 `HomePage`
  8. 后台预热 WebView 引擎（仅移动端非低内存模式）
- **弹窗词典入口**：`lib/popup_main.dart` -- `@pragma('vm:entry-point') popupMain()`
- **悬浮词典入口**：`lib/floating_dict_main.dart`

## 对外接口

本模块是最终应用层，不对外暴露 library API。内部按 barrel file 组织导出：

| Barrel 文件 | 职责 |
|-------------|------|
| `lib/creator.dart` | Anki 卡片创建器（fields / enhancements / actions） |
| `lib/media.dart` | 媒体类型/源（reader / dictionary） |
| `lib/models.dart` | 应用状态模型 |
| `lib/pages.dart` | 所有页面 |
| `lib/utils.dart` | 工具组件/国际化/自适应 UI |

## 关键子系统

### 1. EPUB 阅读器 (`lib/src/epub/`)

- `EpubParser` -- EPUB 解析。
- `EpubImporter` -- EPUB 导入到数据库。
- `EpubBook` -- EPUB 书籍模型。
- `EpubStorage` -- EPUB 文件存储管理。
- `BookCssRepository` -- 自定义 CSS 管理。
- `EpubSpreadAnalyzer` / `EpubSpreadMap` / `EpubEdgeMatcher` -- 双页展开分析。

### 2. 阅读器渲染 (`lib/src/reader/`)

- `ReaderContentStyles` -- 阅读器内容 CSS 样式。
- `ReaderPaginationScripts` -- 分页 JavaScript。
- `ReaderResourceSanitizer` -- 资源路径安全处理。
- `ReaderSelectionData` / `ReaderSelectionScripts` -- 划词选择处理。
- `ReaderSettings` -- 阅读器设置。

### 3. 有声书桥接 (`lib/src/media/audiobook/`)

- `AudiobookBridge` / `HighlightBridge` -- WebView-音频同步桥接。
- `AudiobookImportDialog` / `BookImportDialog` -- 导入对话框。
- `FloatingLyricChannel` -- 悬浮歌词通道。
- `LyricsModeHtml` -- 歌词模式 HTML 生成。
- `SasayakiRematch` -- 重新匹配。
- `TextToEpub` -- 文本转 EPUB。

### 4. Anki 卡片创建器 (`lib/src/creator/`)

- 20+ 字段实现（term / reading / meaning / sentence / image / audio / pitch / frequency / cloze / tags 等）。
- 15+ 增强功能（词典搜索 / 句子选择 / 音频录制 / 图片裁剪 / 文本分段 等）。
- 4 个快捷操作（添加到暂存 / 复制 / 分享 / 播放音频）。

### 5. 应用模型 (`lib/src/models/`)

- `AppModel` -- 全局应用状态（Riverpod `appProvider`，~3600 行），管理初始化、主题、语言、词典、导航。
  - **初始化流程** (`initialise()`): PackageInfo → 目录创建 → Drift DB 打开 → 偏好加载 → Profile 确保 → 词典缓存 → 媒体历史 → 主题调色板 → 语言/格式/增强/快捷操作注册 → 搜索预热
  - **词典搜索** (`searchDictionary()`): emoji/标点/孤立代理项清洗 → 缓存查找 → HoshiDicts FFI lookup → 结果构建
  - **词典导入** (`importDictionary()` / `importDictionaryFromDirectory()`): 格式自动检测(zip/dsl/mdx) → hoshidicts FFI 导入 → 资源目录写入 → 词典类型检测(term/freq/pitch/kanji)
  - **媒体管理** (`openMedia()` / `closeMedia()`): 沉浸模式 → 自适应路由 → wakelock → 音频服务
  - **子系统委托**: 主题 → `ThemeNotifier`，偏好 → `PreferencesRepository`，历史 → `MediaHistoryRepository`，词典 → `DictionaryRepository`
  - **弹窗词典入口** (`initialiseForDictionaryPopup()`): 精简初始化路径（跳过 MediaSource、QuickAction）
- `CreatorModel` -- 卡片创建器状态。
- `DictionaryRepository` -- 词典仓库。
- `MediaHistoryRepository` -- 媒体历史仓库。
- `PreferencesRepository` -- 偏好仓库。
- `ThemeNotifier` -- 主题状态管理。

### 6. Profile 系统 (`lib/src/profile/`)

- `ProfileRepository` / `ProfileSelector` / `ProfileViewModel` -- 多 Profile 管理。
- `ProfileKeys` -- Profile 设置键定义。

### 7. 自适应 UI (`lib/src/utils/adaptive/`)

- `AdaptivePlatform` -- 平台检测。
- `AdaptiveNavigation` -- 自适应导航。
- `AdaptiveTheme` -- 自适应主题。
- `AdaptiveWidgets` -- 自适应组件。
- `HibikiAdaptive` -- 统一入口。

### 8. 页面 (`lib/src/pages/implementations/`)

64 个页面实现，主要包括：
- `home_page.dart` / `home_reader_page.dart` / `home_dictionary_page.dart` -- 首页。
- `reader_hibiki_page.dart` (~7300 行) -- 核心阅读器页面：
  - **WebView 架构**: `InAppWebView` + `hoshi.local` 虚拟域名拦截（`shouldInterceptRequest`），EPUB HTML/CSS/字体/图片全部经过安全校验后在拦截器中提供。
  - **分页系统**: JS 端 `hoshiReader` 分页引擎 + Dart 端 `ReaderPaginationScripts`，支持分页/连续两种模式。
  - **文本选择**: JS `onTextSelected` → Dart `ReaderSelectionData` → 词典查询 → 浮层展示。
  - **手势系统**: 触摸/指针/滚轮统一处理（滑动翻页、点击高亮、双击振假名切换、图片点击查看）。
  - **有声书集成**: `AudiobookPlayerController` + `AudiobookBridge` + `HighlightBridge`，支持 cue 同步高亮、跨章节追踪、音量键句子导航。
  - **歌词模式**: 独立 HTML 页面（`LyricsModeHtml`），支持收藏句子高亮、实时样式更新。
  - **位置保存**: section + normCharOffset (0-10000) 双维度，debounce 写入 DB。
  - **阅读统计**: `ReadingTimeTracker` + 字符计数，session 级别统计。
  - **Profile 系统**: 按 bookUid + mediaType 自动解析并切换 Profile。
  - **自定义字体**: 白名单校验 + 文件头魔数验证（TrueType/OpenType/WOFF/WOFF2/TTC）。
- `reader_hibiki_history_page.dart` -- 阅读器与书架。
- `dictionary_*` 系列 -- 词典相关页面。
- `hibiki_settings_page.dart` / `display_settings_page.dart` / `switch_settings_page.dart` -- 设置。
- `profile_management_page.dart` -- Profile 管理。
- `collections_page.dart` / `tag_*` 系列 -- 集合与标签。
- `reading_statistics_page.dart` -- 阅读统计。

## 关键依赖与配置

- **状态管理**：`flutter_riverpod: ^2.3.6`
- **数据库**：`drift: ^2.23.0` + `sqlite3_flutter_libs`（通过 `hibiki_core`）
- **WebView**：`flutter_inappwebview: ^6.1.5`
- **音频**：`just_audio: ^0.9.31`（通过 `hibiki_audio`）
- **国际化**：`slang: ^3.13.0` / `slang_flutter`，17 种语言
- **内部包**：`hibiki_core` / `hibiki_dictionary` / `hibiki_anki` / `hibiki_audio` / `hibiki_platform`
- **dependency_overrides**：`flutter_inappwebview_windows` / `flutter_inappwebview_android` / `network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `ffmpeg_kit_flutter` / `media_kit_*` 等 vendored 本地包（见 `hibiki/pubspec.yaml` 与 `docs/agent/build.md`）；`file_picker` 用 pub.dev 版（**不是** fork）

## 数据模型

数据模型全部定义在 `hibiki_core`（28 张 Drift 表），本模块仅消费。

## 测试与质量

测试覆盖范围广泛，位于 `test/` 下，约 100+ 测试文件：

| 目录 | 覆盖范围 |
|------|----------|
| `test/database/` | 数据库 CRUD、迁移、并发、外键 |
| `test/epub/` | EPUB 解析、存储、CSS、spread map |
| `test/creator/` | 卡片字段值、频率、pitch accent |
| `test/media/audiobook/` | 全部字幕解析器、匹配算法、播放控制 |
| `test/models/` | AppModel、仓库层 |
| `test/pages/` | 页面 widget 测试 |
| `test/reader/` | 阅读器 CSS/JS/分页/选区 |
| `test/widgets/` | 共享组件 |
| `test/goldens/` | 黄金截图测试 |
| `test/i18n/` | 国际化完整性 |
| `test/utils/` | 转换器测试 |
| `test/profile/` | Profile 键测试 |
| `integration_test/` | 冒烟测试、回归测试、用户路径、阅读器词典测试 |

## Android 原生代码 (`android/`)

18 个 Java 文件，包括：
- `MainActivity.java` -- 主 Activity。
- `PopupDictActivity.java` -- 弹窗词典 Activity。
- `FloatingDictService.java` / `FloatingLyricService.java` / `BaseFloatingService.java` -- 悬浮窗服务。
- `DictAccessibilityService.java` -- 无障碍服务。
- `AnkiChannelHandler.java` / `AnkiDroidHelper.java` -- AnkiDroid 集成。
- `TtsChannelHandler.java` -- TTS 通道。
- `HibikiFileProvider.java` -- 文件提供者。
- `AacAdtsCueAudioRewriter.java` -- AAC 音频重写。

## 资产文件 (`assets/`)

- `assets/meta/` -- 启动图标、splash 图。
- `assets/popup/` -- 弹窗词典 HTML/JS/CSS。
- `assets/transforms/` -- 语言变换表 JSON（ja/en/ko/zh 等 20 种语言）。
- `assets/licenses/` -- 开源许可。

## 相关文件清单

- `lib/main.dart` -- 主入口
- `lib/popup_main.dart` -- 弹窗词典入口
- `lib/floating_dict_main.dart` -- 悬浮词典入口
- `lib/creator.dart` / `lib/media.dart` / `lib/models.dart` / `lib/pages.dart` / `lib/utils.dart` -- barrel files
- `lib/src/epub/` -- EPUB 处理（10 文件）
- `lib/src/reader/` -- 阅读器渲染（6 文件）
- `lib/src/media/audiobook/` -- 有声书桥接（10 文件）
- `lib/src/creator/` -- 卡片创建器（~50 文件）
- `lib/src/models/` -- 应用模型（6 文件）
- `lib/src/pages/` -- 页面（~62 文件）
- `lib/src/utils/` -- 工具（~45 文件）
- `lib/src/profile/` -- Profile 系统（4 文件）
- `lib/src/anki/` -- Anki ViewModel（1 文件）
- `lib/i18n/` -- 国际化（17 语言 + 生成文件）

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
