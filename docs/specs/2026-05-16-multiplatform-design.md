# Hibiki 多平台适配设计

> 日期：2026-05-16（更新：2026-05-19）
> 状态：Active — Phase 0 完成, Phase 1 基本完成, Phase 2/3 计划已完善
> 目标平台：Android（现有）、Windows、macOS、iOS

## 1. 背景与动机

Hibiki 当前是 Android 专属的沉浸式阅读器（EPUB + 词典 + Anki + 有声书同步）。用户希望扩展到 Windows、macOS、iOS，实现完整功能移植，每个平台使用原生 UI 风格。

**核心约束：**
- 不能破坏 Android 版的任何现有功能
- Windows 优先开发（当前开发机是 Windows）
- 每个平台使用原生设计语言（Material / Fluent / Cupertino / macOS native）

## 2. 架构

### 2.1 Monorepo 结构

```
hibiki/
├── packages/
│   ├── hibiki_core/            # 纯 Dart：模型、数据库(Drift)、i18n、LanguageConfig 抽象接口
│   ├── hibiki_dictionary/      # 词典抽象 + hoshidicts FFI 多平台 binding + Language 实现
│   ├── hibiki_anki/            # Anki 抽象接口（AnkiDroid / AnkiConnect / .apkg）
│   ├── hibiki_audio/           # 音频播放/录音 + 字幕解析器(SRT/VTT/LRC/ASS/SMIL) + AudioCue 模型
│   └── hibiki_platform/        # 平台服务抽象（文件选择、分享、TTS、窗口管理）
├── apps/
│   ├── android/                # Android app shell（Material Design 3）+ 平台实现注入
│   ├── windows/                # Windows app shell（Fluent Design）+ 平台实现注入
│   ├── macos/                  # macOS app shell（macos_ui）+ 平台实现注入
│   └── ios/                    # iOS app shell（Cupertino）+ 平台实现注入
├── native/
│   └── hoshidicts/             # hoshidicts C++ 源码 + CMakeLists.txt（.so/.dll/.dylib/.xcframework）
├── melos.yaml
└── pubspec.yaml                # workspace root
```

**设计决策：** Language 模块（`language.dart` + implementations）与词典引擎紧耦合（lookup/deinflection 调用），放入 `hibiki_dictionary` 而非 `hibiki_core`。`hibiki_core` 只定义 `Language` 抽象类接口（不含词典操作）。UI 组件不进 packages——各 app shell 用各自的 UI 框架（Material/Fluent/macos_ui/Cupertino）直接实现页面，共享的是业务逻辑而非 widget。

### 2.2 依赖方向

```
apps/*  -->  packages/*  -->  (Dart SDK, third-party pub packages)
apps/*  -->  native/* (via dart:ffi)

包间依赖（无循环）：
  hibiki_core          不依赖其他 hibiki 包（最底层：模型、数据库、i18n、LanguageConfig 抽象接口）
  hibiki_dictionary  -> hibiki_core（DictEntry 模型、数据库 DAO、LanguageConfig 接口；包含 Language implementations）
  hibiki_anki        -> hibiki_core（AnkiNote 模型、偏好设置）
  hibiki_audio       -> hibiki_core（AudioCue/书籍模型；包含全部字幕解析器 + text_file_io）
  hibiki_platform    -> hibiki_core（存储路径配置、偏好设置）
```

packages 之间不允许循环依赖。每个 app shell 负责注册该平台的具体实现（通过 Riverpod Provider override）。

> **耦合说明：** 当前 `language/` 模块深度依赖 `dictionary/`（lookup/deinflection）、`models/app_model.dart`（3,456 行 God object）和 `utils/`（含 UI widget）。Phase 0 的首要任务是解耦：提取 `LanguageConfig` 抽象接口到 `hibiki_core`（纯元数据，无词典操作），Language 具体实现到 `hibiki_dictionary`，并通过依赖注入替代对 AppModel 的直接引用（实际仅使用 `dictionaryFontSize: double` 一个属性）。

### 2.3 平台抽象层

每个平台差异点定义为抽象接口，放在对应的包中，由各 app shell 提供实现并通过 Riverpod 注入。

```dart
// hibiki_anki/lib/src/anki_service.dart
abstract class AnkiService {
  Future<List<DeckInfo>> getDecks();
  Future<List<ModelInfo>> getModels();
  Future<List<String>> getModelFields(String modelName);
  Future<void> addNote(AnkiNote note);
  Future<bool> isDuplicateNote(String deckName, String fieldValue);
  Future<bool> isAvailable();
}

// hibiki_dictionary/lib/src/dictionary_engine.dart
abstract class DictionaryEngine {
  Future<ImportResult> importDictionary(String zipPath, String outputDir);
  void addTermDict(String path);
  void addFreqDict(String path);
  void addPitchDict(String path);
  void loadTransforms(String json);
  List<LookupResult> lookup(String text, {int maxResults = 10, int scanLength = 20});
  QueryResult query(String expression);
  Map<String, String> getStyles();
  Uint8List? getMedia(String dictName, String mediaPath);
  void dispose();
}

// hibiki_platform/lib/src/platform_services.dart
abstract class TtsEngine {
  Future<void> speak(String text, {String? language});
  Future<void> stop();
  Future<List<String>> getAvailableLanguages();
}

abstract class PlatformIntegration {
  Stream<String> get incomingTextStream;
  Future<String?> pickFile({List<String>? allowedExtensions});
  Future<void> setWakeLock(bool enabled);
}

abstract class StoragePaths {
  Directory get dictionaryDir;
  Directory get bookDir;
  Directory get audioDir;
  Directory get cacheDir;
}
```

## 3. 各模块跨平台方案

### 3.1 hoshidicts C++ 词典引擎

**现状分析：**
- ~3,600 行核心 C++（.cpp + .hpp）+ 391 行 FFI 桥接，16 个公开 C 函数
- C++23，依赖全部 vendor（glaze, zstd, libdeflate, unordered_dense, utf8-cpp, xxHash）
- 已有 Windows/Unix mmap 抽象（memory.cpp 中 `#ifdef _WIN32` + `CreateFileMapping`/`MapViewOfFile`）
- 唯一 Android 依赖：`__android_log_print`（仅警告日志，6 处调用：query.cpp×1, importer.cpp×3, deinflector.cpp×2 via macro）
- 内建 deinflector（词形还原完全在 C++ 侧实现，不依赖外部 Ve/MeCab）
- 无 JNI，纯 C FFI 接口
- 线程：pthread（32MB 栈，用于词典导入解压）

**跨平台改动：**

| 项目 | 改动 |
|------|------|
| 日志 | `#ifdef __ANDROID__` 保留 android log；其他平台用 `fprintf(stderr, ...)` |
| 线程 | 词典导入线程需要 32MB 栈（解压缓冲区）。`std::thread` 无法指定栈大小（Windows 默认 1MB 会栈溢出）。方案：将解压缓冲区从栈分配改为堆分配（`std::vector` / `std::unique_ptr<char[]>`），然后用 `std::thread` 替代 `pthread`。如果堆分配性能不够，Windows 退到 `_beginthreadex` + 显式栈大小 |
| 符号导出 | 统一宏：`#ifdef _WIN32` 用 `__declspec(dllexport)`，否则用 `__attribute__((visibility("default")))` |
| CMake | 统一入口 CMakeLists.txt，通过 `CMAKE_SYSTEM_NAME` 分支处理链接库和输出格式 |

**编译产物与集成方式：**

| 平台 | 产物 | 工具链 | 集成 |
|------|------|--------|------|
| Android | `libhoshidicts_ffi.so` | NDK 27 + CMake | 现有 android/app/build.gradle externalNativeBuild |
| Windows | `hoshidicts_ffi.dll` | MSVC (VS 2022 Build Tools 17.6+) + CMake | Flutter plugin CMakeLists.txt，DLL 自动复制到 exe 同级 `data/` 目录 |
| macOS | `libhoshidicts_ffi.dylib` | Apple Clang + CMake | Flutter plugin podspec，dylib 嵌入 app bundle Frameworks/ |
| iOS | `hoshidicts_ffi.xcframework` | Xcode + CMake (ios-cmake toolchain) | Flutter plugin podspec，静态链接进 Runner |

**Dart FFI 适配：**

```dart
// hibiki_dictionary/lib/src/hoshidicts_ffi_bindings.dart
DynamicLibrary _openLib() {
  if (Platform.isAndroid) return DynamicLibrary.open('libhoshidicts_ffi.so');
  if (Platform.isWindows) {
    // Flutter Windows plugin 机制会将 DLL 放到 exe 同级目录
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return DynamicLibrary.open('$exeDir/hoshidicts_ffi.dll');
  }
  if (Platform.isMacOS) {
    // macOS app bundle: Runner.app/Contents/Frameworks/
    return DynamicLibrary.open('libhoshidicts_ffi.dylib');
  }
  if (Platform.isIOS) {
    // iOS 静态链接，符号已在主进程中
    return DynamicLibrary.process();
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}
```

**风险：** C++23 在 MSVC 上的支持可能有边缘问题（glaze 重度使用 C++23 反射和 concepts）。glaze 官方 CI 包含 MSVC 测试，但需要 VS 2022 17.6+。如果 MSVC 编译失败，可降级到 Clang-cl（MSVC 兼容的 Clang 前端）。

### 3.2 WebView（EPUB 阅读器）

**方案：升级 flutter_inappwebview 到 6.x**

| 事实 | 详情 |
|------|------|
| 6.x 平台支持 | Android (WebView), iOS (WKWebView), macOS (WKWebView), Windows (WebView2) |
| 最新稳定版 | 6.1.5（windows 子包 0.6.0），6.2.0-beta.3 已发布 |
| 当前 fork | arianneorpilla/flutter_inappwebview（旧版，无 Windows/macOS 支持） |
| Windows 依赖 | Edge WebView2 Runtime（Win10 1803+ 预装，Win11 默认有） |

**迁移步骤：**
1. Diff 当前 fork 与原版上游，列出全部自定义改动
2. 评估每个改动在 6.x API 中的等价实现方式
3. 在 6.x 基础上重新应用（优先用 6.x 原生 API，减少 fork 面积）
4. Android 上完整回归测试阅读器功能
5. 依次在 Windows / macOS / iOS 上验证

**需要审计的自定义点（6 项）：**
1. 自定义 URL scheme 拦截（`reader_hoshi://`）—— 6.x 有 `WebResourceRequest` 拦截 API
2. JavaScript 注入与回调桥接 —— 6.x 有 `addJavaScriptHandler` / `evaluateJavascript`
3. 资源拦截（CSS/字体/图片从本地加载）—— 6.x 有 `shouldInterceptRequest`
4. 滚动位置同步 —— JS bridge 实现，平台无关
5. 文本选择事件捕获 —— JS `selectionchange` 事件 + bridge
6. Cookie / Storage 管理 —— 6.x 有 `CookieManager` / `WebStorageManager`

**降级方案：** 如果 6.x 升级风险过大，Windows 端可用 `webview_windows`（成熟的 WebView2 独立插件）单独封装，通过 `WebViewFactory` 抽象层在各平台选择不同实现。

### 3.3 Anki 集成

| 平台 | 方案 | 依赖 |
|------|------|------|
| Android | AnkiDroid API（现有 MethodChannel） | AnkiDroid 安装 |
| Windows | AnkiConnect HTTP API (localhost:8765) | Anki Desktop + AnkiConnect 插件 |
| macOS | AnkiConnect HTTP API (localhost:8765) | Anki Desktop + AnkiConnect 插件 |
| iOS | .apkg 文件导出 -> Share Sheet | AnkiMobile 安装（付费 $24.99） |

**AnkiConnect 客户端实现（`hibiki_anki` 包内）：**
- HTTP POST to `http://localhost:8765`，请求格式：`{"action": "...", "version": 6, "params": {...}}`
- 核心操作：`deckNames`, `modelNames`, `modelFieldNames`, `addNote`, `findNotes`, `guiAddCards`
- 连接检测：启动时 POST `{"action": "version", "version": 6}`，失败时在设置页提示用户检查 Anki Desktop 运行状态和 AnkiConnect 插件安装情况
- 错误处理：AnkiConnect 返回 `{"result": null, "error": "..."}` 时解析 error 字段展示给用户

**.apkg 导出（iOS 方案）：**
- 在 app 内生成 SQLite 格式的 `collection.anki21` + `media` 文件映射
- 打包为 `.apkg`（标准 ZIP 格式：`collection.anki21` + 编号的 media 文件 + `media` JSON 映射）
- 通过 iOS Share Sheet 分享到 AnkiMobile 或 Files
- 限制：不支持实时查重、不能获取已有 deck/model 列表

### 3.4 音频系统

| 组件 | 当前（Android） | 多平台方案 |
|------|----------------|------------|
| 播放 | just_audio 0.9.31 | just_audio（已支持 Android/iOS/macOS/Windows/Linux/Web） |
| 后台播放 | audio_service 0.18.9 | audio_service（已支持 Android + iOS；桌面端进程常驻不需要后台保活） |
| 录音 | record_mp3_plus（Android only） | `record` 包（全平台：Android/iOS/macOS/Windows/Linux，Windows 用 MediaFoundation） |
| 系统媒体控制 | MediaSession via audio_service | Android: MediaSession；Windows: SMTC (via audio_service)；macOS: MPNowPlayingInfoCenter；iOS: Control Center |

### 3.5 NLP / 词形还原

**现状：** 词形还原（deinflection）和文本扫描（scan-based lookup）完全由 hoshidicts C++ 引擎内建实现。`hoshidicts_lookup` FFI 函数接收文本、最大结果数和扫描长度，返回 deinflected 词形、变换链（trace）和词典条目。**不依赖外部 Ve 或 MeCab。**

| 组件 | 现状 | 跨平台方案 |
|------|------|-----------|
| 词形还原 (deinflection) | hoshidicts 内建 `deinflector.cpp` | 随 hoshidicts 跨平台，无需额外工作 |
| 文本扫描 (scan lookup) | hoshidicts 内建 `hoshidicts_lookup` | 随 hoshidicts 跨平台，无需额外工作 |
| 日语文本分割 | hoshidicts scan 逐字符前向匹配 | 已跨平台 |

> **注：** 旧项目 `chisa/` 曾使用 mecab_dart 0.1.3 + ipadic 资产做分词。当前 Hibiki 已完全迁移到 hoshidicts 内建方案，无需 MeCab。如果未来需要更精细的语法分析（如品词标注），可作为独立功能计划引入，不属于多平台适配范围。

### 3.6 UI 框架

| 平台 | 框架 | 包 | 导航模式 |
|------|------|-----|----------|
| Android | Material Design 3 | Flutter 内置 `material` | 底部导航栏 + 抽屉 |
| Windows | Fluent Design | `fluent_ui` 4.x | 左侧 NavigationPane |
| macOS | macOS native | `macos_ui` | MacosSidebar + Toolbar |
| iOS (Phone) | Cupertino | Flutter 内置 `cupertino` | 底部 CupertinoTabBar |
| iOS (iPad) | Cupertino + 分屏 | Flutter 内置 `cupertino` | 侧边 Sidebar + 内容区（类 macOS 布局） |

**UI 实现策略：**

各 app shell 自己实现页面，共享的是 packages/ 中的业务逻辑（Provider / Repository / UseCase），不是 widget。阅读器的 WebView 渲染区域在所有平台上是统一的（ttu ebook reader HTML/JS/CSS），平台差异仅在外壳（工具栏、设置面板、词典弹窗的 UI 框架）。

**桌面专属交互（Windows + macOS）：**
- 键盘快捷键：翻页(Left/Right)、查词(Ctrl/Cmd+D)、制卡(Ctrl/Cmd+E)、全屏(F11)
- 鼠标悬停查词（可选，通过 JS bridge 监听 mouseover）
- 窗口大小/位置记忆（`window_manager` 包）
- 多面板布局（书架 + 阅读器 + 词典可并排）
- 拖拽导入 EPUB/词典文件（`desktop_drop` 包）

**iPad 适配：**
- 检测 `MediaQuery` 宽度，>= 768px 切换为 sidebar 布局
- 支持 iPadOS Split View / Slide Over
- 外接键盘快捷键复用桌面逻辑

### 3.7 Android-only 功能替代

| 功能 | Android 实现 | Windows/macOS | iOS |
|------|-------------|---------------|-----|
| 浮窗词典 | SYSTEM_ALERT_WINDOW + Service | 独立子窗口（`window_manager`） | 不支持（系统限制） |
| 无障碍剪贴板监听 | AccessibilityService | 全局热键 + 剪贴板监听（`hotkey_manager`） | 不支持 |
| Intent 接收文本 | receive_intent | URI scheme `hibiki://lookup?text=` + .epub 文件关联 | Share Extension |
| 音量键翻页 | MethodChannel | 键盘方向键 | 不支持 |
| TTS | Android TTS | Windows: SAPI (`flutter_tts`) / macOS: AVSpeechSynthesizer | AVSpeechSynthesizer (`flutter_tts`) |
| 通知栏播放控制 | Foreground Service + MediaSession | SMTC / MPNowPlayingInfoCenter（via `audio_service`） | Control Center |

### 3.8 数据与存储

| 组件 | 方案 |
|------|------|
| 主数据库 (Drift/SQLite) | 天然跨平台，无需改动。各平台 `getApplicationSupportDirectory()` |
| 词典文件存储 | 各平台 Application Support / AppData 目录 |
| 偏好设置 | 保留 Drift preferences 表（已跨平台） |
| EPUB 文件 | 各平台文档目录。桌面端额外支持自定义路径 |
| 数据迁移 | Phase 4：导出为 JSON/ZIP 包，各平台导入 |

## 4. 依赖替换清单

| 当前依赖 | 当前平台 | 多平台替代 | 说明 |
|----------|---------|-----------|------|
| flutter_inappwebview (fork) | Android | flutter_inappwebview 6.x | 需合并 fork 自定义改动 |
| record_mp3_plus 1.2.0 | Android | `record` 包 | Windows 用 MediaFoundation |
| receive_intent (fork) | Android | 各平台原生机制 | URI scheme / Share Extension |
| wakelock_plus 1.1.4 | 全平台 | 保留 | 已支持 Android/iOS/macOS/Windows（已完成迁移） |
| audio_service 0.18.9 | Android | 保留 | 已支持 Android + iOS；桌面不需要 |
| file_picker 5.3.0 | 全平台 | 保留（升级到最新） | 已支持全平台 |
| filesystem_picker (fork) | Android | `file_picker` | 统一用 file_picker |
| path_provider | 全平台 | 保留 | 已支持全平台 |
| shared_preferences | 全平台 | 保留 | Anki 配置等（已跨平台） |
| flutter_native_splash | 移动端 | 移动端保留，桌面不需要 | 桌面启动速度快无需 splash |

## 5. flutter_inappwebview 6.x 升级风险评估

这是最大的单点风险。当前 fork 是旧版，6.x 是 federated plugin 架构（每个平台一个子包），API 有破坏性变更。

**需要审计的自定义点（10 个文件，8 类使用模式）：**

| 自定义功能 | 涉及文件 | 6.x 对应 API | 风险 |
|-----------|---------|-------------|------|
| URL scheme 拦截 (`reader_hoshi://`) | reader_hoshi_page, dictionary_popup_webview | `shouldInterceptRequest` / custom scheme handler | 低 |
| JS 注入与回调（11+ handler） | dictionary_popup_webview, reader_hoshi_page, audiobook_bridge | `addJavaScriptHandler` / `evaluateJavascript` | 低 |
| 资源拦截（本地 CSS/字体） | reader_hoshi_page, dictionary_popup_webview | `shouldInterceptRequest` | 中 |
| 滚动位置同步 | reader_hoshi_page (JS bridge) | 平台无关 | 低 |
| 文本选择捕获 | dictionary_popup_webview (JS `selectionchange`) | 平台无关 | 低 |
| Cookie/Storage | — | `CookieManager` / `WebStorageManager` | 低 |
| **HeadlessInAppWebView（无头 WebView）** | ttu_idb_reader, reading_statistic_idb_reader, **main.dart** | `HeadlessInAppWebView` | 中 |
| **CSS Highlights API 注入** | highlight_bridge | `evaluateJavascript` 注入非标准 CSS API | 低 |

> **注：** `HeadlessInAppWebView` 用于 3 个场景：(1) TTU 历史数据迁移（IndexedDB 读取）、(2) 阅读统计迁移、(3) 引擎预热。其中 (1)(2) 是迁移代码，不需要跨平台；(3) 的引擎预热模式在 6.x 中可能有变化。

**缓解策略：**
- Phase 0 做 6.x 升级 PoC，在 Android 上验证全部使用模式（逐文件）
- 如果某个功能在 6.x 上无法实现，记录并设计 workaround
- 保留旧 fork 作为 Android fallback，直到 6.x 完全验证通过
- Windows 最坏情况退到 `webview_windows` 包（成熟的 WebView2 独立插件）

## 6. 开发路线图

### Phase 0 -- 基础设施（3-4 周）

**目标：** 建立 monorepo，抽出核心包，Android 版用新架构跑通不回归。

| 子任务 | 内容 |
|--------|------|
| melos 搭建 | `melos.yaml`、workspace `pubspec.yaml`、CI 脚本 |
| hibiki_core 抽包 | LanguageConfig 接口、模型、Drift 数据库、i18n |
| hibiki_dictionary 抽包 | DictionaryEngine 接口 + hoshidicts FFI binding + Language 实现（依赖 hoshidicts deinflection） |
| hibiki_anki 抽包 | AnkiService 接口 + Android AnkiDroid 实现 |
| hibiki_audio 抽包 | just_audio + record 封装 + 全部字幕解析器(SRT/VTT/LRC/ASS/SMIL/JSON) + AudioCue 模型 |
| hibiki_platform 抽包 | TtsEngine / PlatformIntegration / StoragePaths 接口 |
| inappwebview 6.x PoC | 升级 + Android 全功能回归验证（10 文件 / 8 使用模式逐一确认） |
| **验收** | Android APK 编译通过 (`--release --split-per-abi`)，手动测试全功能：书架导入、阅读器翻页/查词/高亮、词典查询、Anki 制卡、有声书同步播放 |

### Phase 1 -- Windows 版（4-6 周）

**目标：** Windows 上实现全功能阅读器。

| 时间 | 子任务 |
|------|--------|
| Week 1-2 | hoshidicts Windows DLL 编译：安装 VS Build Tools，适配 CMake（符号导出/std::thread 或 _beginthreadex/日志），编译 + FFI 测试词典导入和查询 |
| Week 2-3 | flutter_inappwebview 6.x Windows 集成：EPUB 阅读器在 WebView2 中运行，JS bridge 验证 |
| Week 3-5 | Fluent Design UI shell：NavigationPane 导航、书架（GridView + 封面）、阅读器页面、词典弹窗、设置面板、书籍/词典导入（文件选择 + 拖拽） |
| Week 5-6 | AnkiConnect HTTP 客户端 + 制卡 UI |
| Week 6-7 | 有声书同步、键盘快捷键、窗口管理、Windows 打包（MSIX） |
| **验收** | Windows 版全功能可用；Android 版无回归 |

### Phase 2 -- macOS 版（3-4 周）

**前提：需要一台 Mac 开发机。** macOS 和 iOS 构建依赖 Xcode，无法在 Windows 上完成。可选方案：Mac Mini / MacBook、GitHub Actions macOS runner（CI 编译）、云 Mac 服务（MacStadium / AWS EC2 Mac）。至少需要一台 Mac 用于调试和真机测试。

**目标：** macOS 上实现全功能，大量复用 Phase 1 成果。

| 子任务 | 说明 |
|--------|------|
| hoshidicts .dylib | Apple Clang + CMake 编译 |
| macos_ui shell | MacosSidebar + Toolbar 导航，页面实现 |
| WebView | WKWebView 验证（与 iOS 共享底层引擎） |
| AnkiConnect | 复用 Windows 的 HTTP 客户端代码 |
| macOS 特性 | 菜单栏集成、Dock badge、Spotlight 索引 |
| **验收** | macOS 全功能可用 |

### Phase 3 -- iOS 版（3-4 周）

**目标：** iOS 上实现全功能（Anki 降级为 .apkg 导出）。

| 子任务 | 说明 |
|--------|------|
| hoshidicts .xcframework | Xcode + ios-cmake toolchain，arm64 静态链接 |
| Cupertino UI shell | 手机用 CupertinoTabBar，iPad 用 Sidebar 布局 |
| .apkg 导出 | SQLite 生成 + ZIP 打包 + Share Sheet |
| Share Extension | 接收外部文本进行查词 |
| **验收** | iPhone + iPad 全功能可用 |

### Phase 4 -- 打磨与分发（2-3 周）

| 子任务 | 说明 |
|--------|------|
| CI | GitHub Actions：Android APK + Windows MSIX + macOS DMG + iOS IPA |
| 分发 | Windows: MSIX / winget；macOS: DMG / Homebrew cask；iOS: TestFlight -> App Store |
| 数据迁移 | JSON/ZIP 导出导入，支持跨平台迁移书架和进度 |
| 性能 | 各平台冷启动优化、大词典查询性能测试 |

**总计：14-20 周**（删除 MeCab 跨平台编译后下修；hoshidicts 内建 deinflection 无需额外分词器）

## 7. 风险清单

| # | 风险 | 影响 | 概率 | 缓解 | 状态 |
|---|------|------|------|------|------|
| 1 | flutter_inappwebview 6.x 自定义功能不兼容 | 阅读器核心功能受阻 | 中 | Phase 0 先做 PoC；Windows 备选 webview_windows | ✅ 已解决 — 6.1.5 迁移完成 |
| 2 | hoshidicts C++23 (glaze) 在 MSVC 上编译失败 | 词典引擎不可用 | 低 | glaze 官方 CI 测试 MSVC；最坏退 Clang-cl | ✅ 已解决 — MSVC 19.44 编译通过 |
| 3 | fluent_ui / macos_ui 缺少需要的组件 | 部分 UI 需自定义实现 | 低 | 两个包可用 Flutter 内置 widget 补充 | Phase 2/4 再评估 |
| 4 | 四套 UI 的长期维护成本 | 新功能同步延迟 | 中 | 业务逻辑全在 packages/，UI 变更频率低于逻辑变更 | 决策：Phase 2 先用 Material |
| 5 | Phase 0 monorepo 重构破坏 Android | 主平台不可用 | 中 | 每个抽包步骤后立即编译验证，不批量操作 | ✅ 已解决 — Android 无回归 |
| 6 | iOS App Store 审核 | 分发延迟 | 低 | 预留审核周期，提前准备隐私政策和审核材料 | Phase 3 |
| 7 | macOS/iOS 开发需要 Mac 硬件 | Phase 2/3 无法启动 | 中 | 需提前准备 Mac 开发机；CI 可用 GitHub Actions macOS runner | 仍然阻断 |
| 8 | Language 模块解耦 | Phase 0 增加 1-2 天 | 低 | 审计显示 AppModel 依赖仅 1 个属性 | ✅ 已解决 |
| 9 | Apple Clang C++23 支持不完整 | hoshidicts 在 macOS/iOS 编译失败 | 低 | 要求 Xcode 15.2+；fallback 到 c++2b | Phase 2 新增 |
| 10 | iOS 线程栈限制（32MB→~8MB） | 词典导入崩溃 | 中 | 确认 importer 解压缓冲区是否堆分配；必要时重构 | Phase 3 新增 |
| 11 | WKWebView sandbox 限制 file:// 访问 | EPUB 内图片/字体加载失败 | 中 | 使用 custom URL scheme handler 或 local HTTP server | Phase 2 新增 |
| 12 | .apkg 格式兼容性 | AnkiMobile 无法导入 | 低 | 测试 AnkiMobile 23.x；使用 Anki 2.1 schema | Phase 3 新增 |

## 8. Phase 状态与经验教训（2026-05-19 更新）

### Phase 0: Monorepo 抽包 — ✅ 完成

- 5 个包成功抽出，零循环依赖
- 724 测试全部通过
- flutter_inappwebview 从 Android-only fork 迁移到 6.1.5

### Phase 1: Windows Port — ✅ 基本完成

**已完成：**
- hoshidicts DLL 在 MSVC 19.44 上编译成功（4 个关键修复：NOMINMAX, UTF-8, __cplusplus, EXCLUDE_FROM_ALL）
- 28 个平台守卫发现，21 个已修复，7 个延期
- AnkiConnect HTTP 后端实现
- HibikiToast 桌面 overlay 替代 Fluttertoast
- WebView2 运行时确认；requestAnimationFrame 初始化时序问题已修复

**待办：**
- EPUB 阅读器运行时手动测试
- 词典搜索运行时手动测试
- VS VCTools workload 安装（清理本地 SDK patch）

**关键教训：**
1. MSVC 对 C++23 的支持需要显式开启：`/utf-8 /Zc:__cplusplus /permissive-`
2. WebView2 在初始化阶段 `requestAnimationFrame` 不可靠，需要 `setTimeout` 替代
3. 第三方库的 CMake install 规则与 Flutter 冲突，必须用 `EXCLUDE_FROM_ALL`
4. 平台守卫审计要覆盖所有 11 个 MethodChannel，不能只看启动路径

### Phase 2: macOS Port — 📋 计划已完善

详见 `docs/plans/2026-05-19-phase2-macos-port.md`

**关键阻断项：**
- 需要 Mac 硬件
- 需要创建 `hibiki/macos/` 项目目录
- 需要 hoshidicts CocoaPods podspec
- 需要验证 Apple Clang C++23 支持（Xcode 15+）

### Phase 3: iOS Port — 📋 计划已完善

详见 `docs/plans/2026-05-19-phase3-ios-port.md`

**关键阻断项：**
- 依赖 Phase 2 完成（共享 WKWebView 验证和 Apple 编译链）
- 需要 Apple Developer 账号
- hoshidicts 必须静态链接（iOS 沙盒禁止动态库加载）
- .apkg 导出需要全新实现（iOS 上无 AnkiDroid 也无 AnkiConnect）
- 32MB pthread 栈在 iOS 上可能受限，需要确认 importer 解压缓冲区是否已堆分配

### 2026-05-19 审查发现的跨平台就绪差距

| ID | 严重度 | 状态 | 描述 |
|----|--------|------|------|
| HBK-MP-001 | critical | Phase 2/3 阻断 | CMakeLists.txt 缺少 Apple 平台目标 |
| HBK-MP-002 | critical | Phase 2/3 阻断 | 缺少 hoshidicts iOS/macOS podspec |
| HBK-MP-003 | critical | Phase 2 预期 | macOS 项目目录不存在 |
| HBK-MP-005 | medium | Phase 2/3 分发 | 缺少 entitlements 文件 |
| HBK-MP-006 | medium | Phase 3 | iOS Podfile 缺少 platform 版本 |
| HBK-MP-009 | low | Phase 2 | WKWebView 错误处理待验证 |

详见 `docs/reviews/2026-05-19-multiplatform-readiness-audit.md`

## 9. Apple 平台原生构建集成补充（2026-05-19 新增）

### 9.1 hoshidicts CocoaPods 集成策略

Android 和 Windows 的原生构建集成方式不同，Apple 平台需要第三种：

| 平台 | 构建系统 | 集成方式 | 产物 |
|------|---------|---------|------|
| Android | Gradle + CMake | `externalNativeBuild { cmake }` in build.gradle | .so |
| Windows | Flutter CMake | `add_subdirectory` in windows/CMakeLists.txt | .dll |
| **macOS** | **CocoaPods** | **podspec + source_files 直接编译** | **.dylib（自动 embed）** |
| **iOS** | **CocoaPods** | **podspec + static_framework + source_files** | **静态链接到主二进制** |

关键区别：
- macOS 用动态库，`DynamicLibrary.open('libhoshidicts_ffi.dylib')` 通过 RPATH 解析
- iOS 用静态链接，`DynamicLibrary.process()` 在主进程中查找符号
- 两个平台共享同一份 C++ 源码，通过 podspec 的 `s.platform` 区分

### 9.2 iOS 线程栈限制

Phase 1 的 `platform.hpp` 使用 32MB 栈的 pthread 线程做词典导入。iOS 的限制：
- 默认线程栈：512KB
- 实际上限：~8MB（系统强制）

**必须在 Phase 3 开始前确认：** `importer.cpp` 中解压缓冲区是栈分配还是堆分配。如果是栈分配，需要改为 `std::vector` / `std::unique_ptr<char[]>`。

### 9.3 .apkg 导出（iOS Anki 方案）

iOS 无法使用 AnkiDroid API 或 AnkiConnect，必须实现 .apkg 文件导出：
- 生成 SQLite `collection.anki21` + media 文件映射
- 打包为 ZIP（.apkg）
- 通过 iOS Share Sheet 分享

限制：无法实时查重、无法获取已有 deck/model 列表。UI 需要相应调整。

详见 `docs/plans/2026-05-19-phase3-ios-port.md` Task 4。

## 10. 不在本次范围

- Linux 支持（架构允许未来添加，但不在本期目标）
- Web 版
- 云同步 / 多设备实时同步
- 内购 / 付费功能
