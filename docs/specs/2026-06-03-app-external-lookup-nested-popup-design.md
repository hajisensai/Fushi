# app 外查词统一到 Flutter 嵌套弹窗

- 日期：2026-06-03
- 分支：develop
- 范围：Android 外部查词入口（PROCESS_TEXT / SEND / TRANSLATE / `hibiki://lookup`）
- 方案：A（复用 Flutter `PopupDictionaryPage`，彻底统一）

## 1. 背景与问题

Hibiki 目前有三套查词 UI：

1. **app 内查词（阅读器内）** — `BaseSourcePageState`（`hibiki/lib/src/pages/base_source_page.dart`）。自维护一套层叠栈 `_popupStack` / `_PopupStackItem`，用 `DictionaryPopupWebView`（WebView 渲染 HTML 词条 + 点词回调）实现**真·嵌套查词**：点词 → 截断当前层之后的栈 → 查新词 → push 新层；可逐层返回。
2. **app 外查词 Flutter 版** — `PopupDictionaryPage`（`hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`）。用共享的 `DictionaryPageMixin` + `NestedPopupEntry` + `DictionaryPopupWebView`，**本身已支持嵌套**（`_stack` + `buildNestedPopupLayer` + `PopScope` 返回）。入口 `popupMain()`（`hibiki/lib/popup_main.dart`）+ `PopupChannel`（`hibiki/lib/src/utils/misc/popup_channel.dart`）。**目前仅桌面端在用**（`AppModel.openPopupDictionaryLookup` 非 Android 分支 → `showAppDialog`）。
3. **app 外查词 原生版** — Android `PopupDictActivity.kt`（`hibiki/android/app/src/main/java/app/hibiki/reader/`）。`:popup` 进程里的原生 Kotlin Activity，托管一个 WebView 加载 `assets/popup/` 的 HTML/JS（`renderPopup()`）。

**问题根因**：Android 上 PROCESS_TEXT / SEND / TRANSLATE / `hibiki://lookup` 这 4 个 intent-filter 全部由 `PopupDictActivity`（原生）接管。它虽然有点词回调（`PopupJsInterface.textSelected` / `onLinkClick`），但行为是 `performSearch(text)` **原地替换整张结果**——没有层叠栈、没有"返回上一层"。这就是用户感知的"app 外查词不支持嵌套"。

而 `popupMain` / `PopupChannel` 的原生桥（`getInitialProcessText` / `onNewProcessText` / `finishPopup`）在 Android 侧**根本没有任何组件接管**（`FloatingDictService` 走的是 MainActivity 主引擎的 `notifyFloatingDictEvent`，不跑独立引擎）。即 `popupMain` 在 Android 是死代码，Flutter 版嵌套弹窗从未在 Android 启用。

## 2. 目标

让 Android 外部查词渲染与桌面/app 内**同一套** `PopupDictionaryPage`，获得真·嵌套（层叠下钻 + 逐层返回），替换原生 WebView 的平铺替换行为。单一实现，未来 popup 能力自动覆盖三端。

## 3. 非目标

- 不改 app 内阅读器弹窗（`base_source_page.dart` 的 `_popupStack`）行为。
- 不改桌面端 `PopupDictionaryPage` 现有行为（仅复用）。
- 不改 `FloatingDictService`（悬浮查词，另一条入口，不在本轮范围）。
- 本轮**不删除**原生 `PopupDictActivity` / `HoshiBridge` / `PopupDbReader` / JNI 绑定（见 §6 清理策略）。

## 4. 架构与组件

### 4.1 新建 `PopupDictFlutterActivity`（Kotlin）

`app.hibiki.reader.PopupDictFlutterActivity extends io.flutter.embedding.android.FlutterActivity`：

- **进程/窗口**：`:popup` 进程，透明背景浮于触发它的 App 之上（`backgroundMode=transparent` 或等价透明主题）。浮动卡片尺寸/居中由 Dart 端 `PopupDictionaryPage`（topCenter 卡片 + 点外关闭）负责，原生只需透明全屏 + 不抢焦点行为对齐原生弹窗体验。
- **引擎**：通过缓存的常驻热引擎运行 `popupMain`（见 §4.2），用 `FlutterActivity.withCachedEngine(<engineId>)` 或 `provideFlutterEngine` 返回缓存引擎。
- **取词**：复刻原生 `extractProcessText` 的取文本顺序 —— `Intent.EXTRA_PROCESS_TEXT` → `Intent.EXTRA_TEXT` → `hibiki://lookup?word=`。
- **channel 绑定**（`configureFlutterEngine`）：在引擎的 binaryMessenger 上注册 `app.hibiki.reader/popup` MethodChannel handler（与 Dart `PopupChannel` 对应）：
  - `getInitialProcessText` → 返回 `{text, charIndex}`（charIndex 对外部选词固定 -1 = 查整段选中文本）。
  - `finishPopup` → `finish()`。
- **`onNewIntent`**：热引擎复用时（`singleTop`），解析新 intent 文本 → 通过 channel `invokeMethod('onNewProcessText', {...})` 推给 Dart，免重启换词重搜。

### 4.2 `PopupEngineHolder`（Kotlin）

懒构建 + 缓存热引擎：

- DartEntrypoint = `popupMain`。
- 插件注册：用 `io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)`（**必须包含 `flutter_inappwebview`** —— 嵌套层由 WebView 渲染；以及 drift/sqlite3_flutter_libs、path_provider、package_info、shared_preferences 等 `initialiseForDictionaryPopup` 依赖）。
- 缓存：`io.flutter.embedding.engine.FlutterEngineCache` 以固定 key 存放；首次启动付引擎 boot + `initialiseForDictionaryPopup` 代价，之后复用 → 即时 + `onNewProcessText` 换词。
- 引擎常驻 `:popup` 进程（接受其内存代价）。

### 4.3 Manifest

把 `.PopupDictActivity` 上的 4 个 intent-filter（PROCESS_TEXT / SEND text/* / TRANSLATE / VIEW `hibiki://lookup`）迁到 `.PopupDictFlutterActivity`，保留：`android:process=":popup"`、`launchMode="singleTop"`、`excludeFromRecents`/`autoRemoveFromRecents`、透明主题、`exported="true"`、`configChanges`、`windowSoftInputMode="adjustResize"`。

`.PopupDictActivity` 暂留 `<activity>` 定义但**移除全部 intent-filter**（失活，不再被外部/深链命中）。

### 4.4 Dart 侧

基本零改动。`popupMain` / `PopupDictApp` / `PopupChannel` / `PopupDictionaryPage` 已就绪。`PopupChannel.init` 已在 `onNewProcessText` + `getInitialProcessText` 上消费文本；`PopupDictionaryPage` 已实现 `_stack` 嵌套 + `PopScope` 返回 + `finishPopup` 关闭。如发现 SEND/TRANSLATE 传入整段长文本需特殊处理再评估（默认按整段查，与原生一致）。

## 5. 数据流

```
外部 App 选词 → PROCESS_TEXT intent
  → PopupDictFlutterActivity (:popup)
  → 缓存热引擎 popupMain → PopupChannel.getInitialProcessText 返回文本
  → PopupDictApp 设 searchTerm → PopupDictionaryPage 自动查词
  → base 层 DictionaryPopupWebView 渲染
  → 用户点词 onTextSelected/onLinkClick → _pushSearch push 新层（嵌套）
  → 返回手势 PopScope → 逐层 _popAt
  → 点外/横滑/关闭按钮 → _close() → PopupChannel.finishPopup → finish()
热引擎复用：再次 PROCESS_TEXT → onNewIntent → invokeMethod('onNewProcessText') → 换词重搜
```

## 6. 原生死代码清理策略（先失活后删）

本轮只到"失活"。原生 `PopupDictActivity.kt` / `HoshiBridge.kt` / `PopupDbReader.kt` / `native/hoshidicts/hoshidicts_jni.cpp` 的 HoshiBridge 绑定**暂留**作回退。

原因：
- `assets/popup/*`（popup.js/css）被 Flutter `DictionaryPopupWebView` 共享，**不可删**。
- `HoshiBridge` 连着 JNI cpp，删除牵涉 native 编译面。
- 设备验证通过前保留可快速 manifest 回退。

清理触发条件（另开一轮）：设备验证 4 路径（PROCESS_TEXT / SEND / TRANSLATE / `hibiki://lookup`）全部确认 Flutter 弹窗正常 + 嵌套/返回正常后，删 `PopupDictActivity.kt` + `HoshiBridge.kt` + `PopupDbReader.kt` + JNI 绑定 + 多余的 `:popup` 原生资源引用。

## 7. 风险与权衡（已知并接受）

- **冷启动延迟**：`:popup` 进程首次付 Flutter 引擎 boot + `initialiseForDictionaryPopup`（DB 打开、transform 预载），比原生 WebView 重。热引擎缓存缓解后续启动。
- **透明 FlutterActivity 首帧**：可能轻微闪烁；Dart 端透明 Scaffold 缓解。
- **内存**：`:popup` 常驻一个 Flutter 引擎。
- **插件齐全性**：必须确保 `flutter_inappwebview` 在 popup 引擎注册，否则嵌套层 WebView 白屏。用 `GeneratedPluginRegistrant` 全量注册规避遗漏。

## 8. 测试

- **Dart widget/源测**（`hibiki/test/pages/`）：`PopupDictionaryPage` 给定 searchTerm → base 层就绪；模拟 `onTextSelected` 回调 → `_stack` 长度增至 2（验证嵌套 push）；`_popAt`/返回 → 回退到 1（验证逐层返回）。WebView 内容无法在 widget 测中点击，测栈管理回调层（`_pushSearch` / `_popAt` / `removeRange`）。
- **源码守卫测**：扫描 `AndroidManifest.xml`，断言 PROCESS_TEXT / SEND / TRANSLATE / VIEW(`hibiki://lookup`) 4 个 filter 指向 `PopupDictFlutterActivity`，且 `PopupDictActivity` 不再持有任何 intent-filter。
- **设备验证（CLAUDE.md 强制，reader/查词类必做）**：模拟器上
  - `adb shell am start -a android.intent.action.PROCESS_TEXT -e android.intent.extra.PROCESS_TEXT "日本語" ...`
  - `adb shell am start -a android.intent.action.VIEW -d "hibiki://lookup?word=日本語"`
  - 确认出 Flutter 弹窗 → 点词出嵌套层 → 返回逐层回退 → 截图取证。

## 8.1 设备验证结果（2026-06-03，emulator hoshi_test_api35）

在真机模拟器上实测 release APK（含下述 WebView 修复），全部目标通过：

1. ✅ 外部 `hibiki://lookup?word=...` 与 PROCESS_TEXT 均 resumed 到透明 `PopupDictFlutterActivity`，`:popup` 进程加载 `libflutter.so`+Impeller；旧原生 `PopupDictActivity` `exported=false`，外部直接启动抛 SecurityException（彻底失活）。
2. ✅ 弹出 Flutter `PopupDictionaryPage`（贴顶卡片+搜索栏，透明浮于触发它的画面之上），导入测试词典后正确渲染词条（neko → cat; feline）。
3. ✅ 嵌套下钻：点词条里的词（feline）→ 叠出新层；返回键 pop 回上一层（neko），再返回才关窗——与 app 内逐层返回一致。
4. ✅ 热引擎复用：关窗后再 firing 新词，同一 `:popup` pid、无新引擎加载，搜索栏即时更新（`onNewProcessText` 生效）。

**验证中发现并根因修复的真 bug（develop `84eaf5320`）**：`:popup` 进程的 Flutter 引擎用 flutter_inappwebview 渲染词条，与主进程 WebView 共用同一数据目录触发 `crbug.com/558377`（"Using WebView from more than one process at once with the same data directory"），弹窗在渲染前崩溃（词典查询本身成功 `cache HIT`，但 WebView 抛 PlatformException）。修复：在 `PopupDictFlutterActivity.onCreate` 最早处（任何 WebView 创建前）调 `WebView.setDataDirectorySuffix("popup")`，复刻旧原生 `PopupDictActivity.configureWebViewDataDir()` 的做法；并加源码守卫断言。**这是只有真机能暴露的运行时问题——静态测试 + release 构建均通过却仍崩，印证了设备复测的必要性。**

**已知次要行为（非阻塞）**：`:popup` 热引擎在首次查词时 `initialiseForDictionaryPopup()` 加载词典缓存。若用户在热引擎已存活期间导入新词典，外部查词要等 `:popup` 进程被系统回收/重启后才反映新词典（与旧原生 `HoshiBridge` 进程级缓存特性一致，且 `:popup` 进程短命会自愈）。如需即时反映可后续在 `onNewProcessText` 路径补一次词典缓存刷新。

## 9. 验收标准

1. Android 外部 4 个入口均弹出 Flutter `PopupDictionaryPage`（非原生 WebView 弹窗）。
2. 弹窗内点词产生层叠嵌套层，可逐层返回（与 app 内一致）。
3. 关闭（点外/横滑/返回到底/关闭按钮）正常 `finish()`。
4. 热引擎复用：连续多次外部查词不重复冷启动。
5. `flutter analyze` 干净；新增/修改 Dart 测试 + 源码守卫测试通过；`gradlew :app:assembleRelease` 通过（manifest/原生改动）。
