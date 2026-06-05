# Windows 打开书籍慢 —— 性能修复实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框跟踪。所有派生子代理必须 `model: "opus"`。

**Goal:** 消除 Windows 桌面端首开 EPUB 书籍的两大结构性延迟（WebView2 冷启动 + `_initBook` 串行链 + 冗余整书 isolate 拷贝），让打开书接近移动端速度。

**Architecture:** 三层修复，按收益/风险排序——
- **A（低风险，Windows 收益最大）**：桌面端也预热 WebView2 引擎，把 ~500–1500ms 冷启动在用户翻书架时吃掉。当前 `main.dart:196` 把预热门控成 `Platform.isAndroid || Platform.isIOS`，桌面被排除；根因是"view 未挂载前调 `HeadlessInAppWebView` 会崩 WebView2"，**不是** fork 不支持（fork 自带 `headless_in_app_webview`）。修法是排到首帧之后预热，而非整体跳过。
- **B1（低风险）**：`_initBook` 当前跑两趟 `compute()`——先解析整本书，再把**整本书（含全部章节 HTML）二次序列化进新 isolate** 只为数每章字符数（`_computeChapterCharCounts` 调内存里的 `book.chapterPlainText(i)`，并非重读磁盘）。合并成单趟 isolate，返回 `(book, charCounts)`，省掉一次整书跨 isolate 拷贝。
- **B2（中风险，Stage 2）**：解开 `_buildBody` 对 `_audioSlotResolved` 的门控，让 WebView 在 `_book`+`_extractDir` 就绪即挂载，使 WebView2 controller 创建与音频槽/恢复位置解析**并行**；首章加载在"controller 就绪 ∧ 数据就绪"两信号都到才触发（保歌词模式/章节模式判定不变）。**B2 在 A 落地后边际收益缩小**（环境已预热则 controller 创建变快），故置于最后，A+B1 落地后先在 Windows 真机测时延，再决定是否需要 B2。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；`flutter_inappwebview`（Windows 走 fork `flutter_inappwebview_windows`）；`compute()` isolate；Riverpod。

**关键文件：**
- `hibiki/lib/main.dart`（预热逻辑，`:190-213`）
- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`_initBook` `:330-443`、`_buildBody` `:1201-1206`、`onWebViewCreated` `:1719-1752`、`_computeChapterCharCounts` `:66-71`）
- `hibiki/lib/src/epub/epub_parser.dart`（`EpubParser.parseFromExtracted`）
- `hibiki/lib/src/epub/epub_book.dart`（`EpubBook.chapterPlainText`）

**验证铁律（项目规则）：** `dart format .` + `flutter test`（项目 3.44.0 工具链）；声明"修好了"前必须在 Windows 真机复测原始失败路径（打开书时延）并留证据。性能类改动的自动化测试在"最强可落地层"（单测校验等价性 + widget 校验时序门控 + 源码守卫），真机时延由用户复测。

---

## 前置：确认基线（不改代码，只读）

- [ ] **Step 0.1：确认 fork 支持 HeadlessInAppWebView**

已确认：`packages/flutter_inappwebview_windows/lib/src/in_app_webview/headless_in_app_webview.dart` 与 `windows/headless_in_app_webview/*` 均存在。`HeadlessInAppWebView` 在 Windows fork 可用。无需改动，仅记录前提成立。

---

## Task A：桌面端预热 WebView2 引擎

**Files:**
- Modify: `hibiki/lib/main.dart:192-213`
- Test: `hibiki/test/startup/webview_prewarm_gating_test.dart`（新建）

**背景与不变量：**
- 移动端预热保持原样（`!appModel.lowMemoryMode` 仍生效）。
- 桌面端（Windows/Linux/macOS）也预热，但**必须等首帧渲染、Flutter view 已挂载**后再构造 `HeadlessInAppWebView`，否则按原注释会崩 WebView2。用 `await WidgetsBinding.instance.endOfFrame` 保证 view 已 attach。
- macOS 走 Cupertino/可能不同 webview 后端——预热对 macOS 是中性或正收益；若 macOS 真机出问题，gate 收窄为 `Platform.isWindows || Platform.isLinux`。计划默认全桌面预热，真机验证后按需收窄。

- [ ] **Step A.1：抽出可单测的门控函数（先写失败测试）**

把"是否应预热"的判定从内联条件抽成纯函数，便于测试门控逻辑（真正的 `HeadlessInAppWebView` 调用无法在单测跑，但门控可测）。

新建 `hibiki/test/startup/webview_prewarm_gating_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/webview_prewarm.dart';

void main() {
  group('shouldPrewarmWebView', () {
    test('mobile prewarms when not low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: true, isDesktop: false, lowMemory: false),
        isTrue,
      );
    });

    test('mobile skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: true, isDesktop: false, lowMemory: true),
        isFalse,
      );
    });

    test('desktop prewarms (regression: was mobile-only)', () {
      expect(
        shouldPrewarmWebView(isMobile: false, isDesktop: true, lowMemory: false),
        isTrue,
      );
    });

    test('desktop skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: false, isDesktop: true, lowMemory: true),
        isFalse,
      );
    });

    test('neither mobile nor desktop does not prewarm', () {
      expect(
        shouldPrewarmWebView(isMobile: false, isDesktop: false, lowMemory: false),
        isFalse,
      );
    });
  });
}
```

- [ ] **Step A.2：运行测试确认失败**

Run: `cd hibiki && flutter test test/startup/webview_prewarm_gating_test.dart`
Expected: FAIL —— `webview_prewarm.dart` 不存在 / `shouldPrewarmWebView` 未定义。

- [ ] **Step A.3：实现门控函数**

新建 `hibiki/lib/src/startup/webview_prewarm.dart`：

```dart
/// 是否应在启动后预热 WebView 引擎，把冷启动成本提前到用户翻书架时。
///
/// 移动端与桌面端都预热（桌面端调用时机另由调用方保证在首帧后），
/// 低内存模式一律跳过。纯逻辑，便于单测；真正的 HeadlessInAppWebView
/// 调用留在 main.dart（依赖平台无法单测）。
bool shouldPrewarmWebView({
  required bool isMobile,
  required bool isDesktop,
  required bool lowMemory,
}) {
  if (lowMemory) return false;
  return isMobile || isDesktop;
}
```

- [ ] **Step A.4：运行测试确认通过**

Run: `cd hibiki && flutter test test/startup/webview_prewarm_gating_test.dart`
Expected: PASS（5 例全绿）。

- [ ] **Step A.5：在 main.dart 接入桌面预热（含首帧等待）**

把 `hibiki/lib/main.dart:192-213` 现有块替换为下面（导入 `webview_prewarm.dart`，新增 `import 'dart:io' show Platform;` 若尚未导入——`Platform` 已在 main.dart 使用，无需重复）：

```dart
    // ── 预热 WebView 引擎 ──────────────────────────────────────────────
    // 用户还在看主页/书架时就把冷启动成本吃掉：~500-1500ms。
    // 移动端可直接预热；桌面端（WebView2）必须等首帧渲染、Flutter view
    // 已挂载后再构造 HeadlessInAppWebView，否则会崩 WebView2。
    final bool isMobilePlatform = Platform.isAndroid || Platform.isIOS;
    final bool isDesktopPlatform =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (shouldPrewarmWebView(
      isMobile: isMobilePlatform,
      isDesktop: isDesktopPlatform,
      lowMemory: appModel.lowMemoryMode,
    )) {
      unawaited(Future(() async {
        try {
          // 桌面端等首帧，保证 Flutter view 已 attach（WebView2 前提）。
          if (isDesktopPlatform) {
            await WidgetsBinding.instance.endOfFrame;
          }
          late final HeadlessInAppWebView warmup;
          warmup = HeadlessInAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('about:blank')),
            onLoadStop: (controller, url) async {
              await Future.delayed(const Duration(milliseconds: 100));
              await warmup.dispose();
              debugPrint('[Hibiki] WebView engine pre-warmed');
            },
          );
          await warmup.run();
        } catch (e) {
          debugPrint('[Hibiki] WebView warmup failed (non-fatal): $e');
        }
      }));
    }
```

在 main.dart 顶部 import 区加：

```dart
import 'package:hibiki/src/startup/webview_prewarm.dart';
```

- [ ] **Step A.6：分析 + 全量测试**

Run: `cd hibiki && dart format . && flutter analyze && flutter test`
Expected: analyze 无新错误；全量测试绿（含 Step A.1 新测）。

- [ ] **Step A.7：提交**

```bash
git add hibiki/lib/main.dart hibiki/lib/src/startup/webview_prewarm.dart hibiki/test/startup/webview_prewarm_gating_test.dart
git commit -m "perf(startup): pre-warm WebView2 engine on desktop too"
```

- [ ] **Step A.8：Windows 真机时延复测（用户）**

在 Windows 真机：冷启动 app → 停在书架几秒（让预热完成，看 debug 日志 `WebView engine pre-warmed`）→ 打开一本书，记录"点击→正文可见"耗时；与改动前对比。留证据。

---

## Task B1：解析与字符计数合并为单趟 isolate

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:66-71`（`_computeChapterCharCounts` 改造）、`:357-381`（`_initBook` 两个 compute 合一）
- Test: `hibiki/test/reader/parse_and_count_test.dart`（新建）

**不变量：** 合并后每章字符数必须与旧 `_computeChapterCharCounts(book)` 逐项相等；`_book` 解析结果不变。

- [ ] **Step B1.1：写失败测试（等价性）**

需要一个已解压的 EPUB fixture 目录。复用 `test/epub/` 既有夹具方式（查 `test/epub/` 下现有解析测试如何拿到 extractDir；若有 `EpubParser.parseFromExtracted` 的测试夹具，照搬其 setup）。

新建 `hibiki/test/reader/parse_and_count_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show parseAndCountChapters; // 见 B1.3 导出

void main() {
  // <extractDir> 用 test/epub 既有夹具路径（照搬现有 epub 解析测试 setUp）。
  late String extractDir;
  setUp(() {
    extractDir = /* 复用 test/epub 夹具：已解压的 EPUB 目录 */ '';
  });

  test('parseAndCountChapters 的字符数与逐章 chapterPlainText 等价', () {
    final result = parseAndCountChapters(extractDir);
    final book = EpubParser.parseFromExtracted(extractDir);

    expect(result.book.chapters.length, book.chapters.length);
    final expected = List<int>.generate(
      book.chapters.length,
      (i) => book.chapterPlainText(i).length,
    );
    expect(result.charCounts, expected);
  });
}
```

> 注：若 `test/epub/` 没有现成"解压目录"夹具（多数 EPUB 测试可能直接对 zip 操作），改为在测试内用既有 import 流程解压一本测试 epub 到临时目录，或复用 `test/epub` 中 `parseFromExtracted` 测试的夹具构造代码。执行者按 `test/epub/` 现状选最贴近的路径，**不要新造夹具体系**。

- [ ] **Step B1.2：运行确认失败**

Run: `cd hibiki && flutter test test/reader/parse_and_count_test.dart`
Expected: FAIL —— `parseAndCountChapters` 未定义。

- [ ] **Step B1.3：实现合并函数（替换 `_computeChapterCharCounts`）**

在 `reader_hibiki_page.dart` 顶部，把 `:66-71` 的 `_computeChapterCharCounts` 替换为：

```dart
/// 解析结果 + 每章字符数，一次 isolate 往返同时算好，避免把整本书
/// （含全部章节 HTML）二次序列化进新 isolate 只为数字符。
class ParsedBookData {
  const ParsedBookData(this.book, this.charCounts);
  final EpubBook book;
  final List<int> charCounts;
}

/// 在单个 isolate 内解析 EPUB 并计算每章纯文本长度。供 compute() 调用，
/// 也 @visibleForTesting 直接调用做等价性校验。
ParsedBookData parseAndCountChapters(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  final List<int> counts = List<int>.generate(
    book.chapters.length,
    (int i) => book.chapterPlainText(i).length,
  );
  return ParsedBookData(book, counts);
}
```

> `parseAndCountChapters` 与 `ParsedBookData` 为顶层 public，使测试可直接 import（与现有顶层 `_computeChapterCharCounts` 不同，去掉下划线）。

- [ ] **Step B1.4：改 `_initBook` 用单趟 compute**

把 `reader_hibiki_page.dart:357-375` 这段：

```dart
    try {
      _book = await compute(EpubParser.parseFromExtracted, extractDir);
      debugPrint(
          '[ReaderHibiki] parsed EPUB: ${_book!.chapters.length} chapters');
    } on FormatException catch (e) {
      debugPrint('[ReaderHibiki] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookId, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir);
      HibikiToast.show(msg: t.epub_parse_fallback);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHibiki] chapter hrefs: $hrefs');

    _chapterCharCounts = await compute(
      _computeChapterCharCounts,
      _book!,
    );
```

替换为：

```dart
    try {
      final ParsedBookData parsed =
          await compute(parseAndCountChapters, extractDir);
      _book = parsed.book;
      _chapterCharCounts = parsed.charCounts;
      debugPrint(
          '[ReaderHibiki] parsed EPUB: ${_book!.chapters.length} chapters');
    } on FormatException catch (e) {
      debugPrint('[ReaderHibiki] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookId, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir);
      // fallback 路径没在 isolate 里算字符数，这里补一趟（书已在内存，便宜）。
      _chapterCharCounts = List<int>.generate(
        _book!.chapters.length,
        (int i) => _book!.chapterPlainText(i).length,
      );
      HibikiToast.show(msg: t.epub_parse_fallback);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHibiki] chapter hrefs: $hrefs');
```

> 保留紧随其后的 `_chapterCumulativeChars` 累加循环（`:376-381`）不动——它消费 `_chapterCharCounts`。fallback 分支补算字符数确保两条路径都填好 `_chapterCharCounts`，与改前行为等价（改前 fallback 也会走到下面那趟 `compute(_computeChapterCharCounts, _book!)`）。

- [ ] **Step B1.5：运行 B1 测试 + 全量**

Run: `cd hibiki && dart format . && flutter analyze && flutter test test/reader/parse_and_count_test.dart && flutter test`
Expected: 等价性测试 PASS；analyze 干净；全量绿。

- [ ] **Step B1.6：提交**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/test/reader/parse_and_count_test.dart
git commit -m "perf(reader): parse EPUB and count chars in one isolate pass"
```

---

## Task B2（Stage 2，A+B1 真机验证后再做）：WebView 提早挂载，首章加载双信号门控

> **决策门：** 先完成 A+B1 并在 Windows 真机测时延。若打开书已够快，**跳过 B2**（A 预热后 controller 创建已变快，B2 边际收益小，而它要动核心时序、风险最高）。只有 A+B1 后仍明显慢、且测得耗时卡在"WebView2 controller 创建串在数据后"才做 B2。

**Files:**
- Modify: `reader_hibiki_page.dart`：`_buildBody`（`:1201-1206`）、`onWebViewCreated`（`:1719-1752`）、`_initBook` 尾部（`:440-442`）、新增状态字段与 `_maybeStartInitialLoad()`。
- Test: `hibiki/test/pages/reader_open_sequencing_test.dart`（新建）

**根因回顾：** `_buildBody:1202` 门控 `_audioSlotResolved && _book != null && _extractDir != null` 把 WebView 挂载推到 `_initBook` 整条 await 链跑完之后，于是最贵的 WebView2 controller 创建与音频槽/恢复位置解析**串行**。但首章"加载哪个页面"确实依赖音频槽（`onWebViewCreated:1738` 按 `_lyricsMode`/`_audiobookController` 选歌词页 vs 章节页）与恢复位置（`_currentChapter`）。

**方案：** 解耦"WebView 挂载（=controller 创建，可早）"与"首章加载（=需数据就绪）"：
1. `_buildBody` 门控放宽为 `_book != null && _extractDir != null` → parse 完即挂 WebView，controller 创建与音频槽解析并行。
2. 新增 `bool _initialLoadStarted = false;`。`onWebViewCreated` 不再直接 `_loadChapterDirectly`，改存 controller 后调 `_maybeStartInitialLoad()`。
3. `_initBook` 尾部把 `_audioSlotResolved = true; setState(() {});` 后追加 `_maybeStartInitialLoad()`。
4. `_maybeStartInitialLoad()`：仅当 `_controller != null && _audioSlotResolved && !_initialLoadStarted` 才置位并执行原 `onWebViewCreated:1738-1752` 的歌词/章节分支逻辑。
5. 挂载期间 chrome 布局：`_buildBody` 在 `!_audioSlotResolved` 时用 `Stack`，底层挂 WebView（让它后台初始化），顶层盖 loading indicator，避免音频铬层在槽未定时跳布局；`_audioSlotResolved` 后移除遮罩。WebView 自身有 cloak 隐藏正文直到 reveal，不会露半成品。

- [ ] **Step B2.1：写失败 widget 测试（时序门控）**

新建 `hibiki/test/pages/reader_open_sequencing_test.dart`，断言：
- (a) `_book`+`_extractDir` 就绪但 `_audioSlotResolved=false` 时，控件树里**已存在** `InAppWebView`（key `hoshi_webview`）——证明 WebView 提早挂载；
- (b) 首章加载（`_loadChapterDirectly` / `loadUrl`）在 `_audioSlotResolved` 变 true **之前不触发**，之后触发一次（用一个可注入的假 controller / 钩子计数 `_loadChapterDirectly` 调用，或断言 `_initialLoadStarted` 翻转时机）。

```dart
// 伪代码骨架——执行者按 test/pages 既有 reader widget 测试夹具补全：
// 1. pump ReaderHibikiPage，stub 出延迟 resolve 的音频槽（注入慢 DB 或 fake）。
// 2. 在音频槽 resolve 前 pump 一帧：expect(find.byKey(ValueKey('hoshi_webview')), findsOneWidget);
//    且 fakeController.loadUrlCallCount == 0。
// 3. 让音频槽 resolve、pumpAndSettle：expect loadUrlCallCount == 1，章节正确。
// 4. 歌词模式分支：_lyricsMode=true 时 resolve 后走 _loadLyricsPage 而非章节。
```

> 若现有测试体系拿不到真实 `InAppWebViewController`（平台通道），用项目既有的 reader widget 测试夹具（查 `test/pages/` 下 reader 相关测试如何 stub WebView）。**不要新造 WebView 假实现体系**；复用现状，断言能观测到的状态字段（如暴露 `@visibleForTesting` 的 `_initialLoadStarted` / `_currentChapter`）。

- [ ] **Step B2.2：运行确认失败**

Run: `cd hibiki && flutter test test/pages/reader_open_sequencing_test.dart`
Expected: FAIL（当前 WebView 被 `_audioSlotResolved` 门控，未提早挂载）。

- [ ] **Step B2.3：实现解耦**

(1) 字段：在 `:172` `_audioSlotResolved` 附近加：

```dart
  bool _initialLoadStarted = false;
```

(2) `_buildBody`（`:1201-1206`）改为：

```dart
  Widget _buildBody() {
    // WebView 在 parse 完成（_book + _extractDir 就绪）即挂载，让 WebView2
    // controller 创建与音频槽/恢复位置解析并行；首章加载另由
    // _maybeStartInitialLoad() 在数据就绪后触发。
    if (_book == null || _extractDir == null) {
      return Center(child: adaptiveIndicator(context: context));
    }
    if (!_audioSlotResolved) {
      // 音频槽未定前用遮罩盖住 WebView（仍在后台初始化），避免铬层跳布局。
      return Stack(
        children: <Widget>[
          _buildWebView(),
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(child: adaptiveIndicator(context: context)),
            ),
          ),
        ],
      );
    }
    return _buildWebView();
  }
```

(3) `onWebViewCreated`（`:1737-1752`）：把 `_startContentReadyTimeout();` 之后的歌词/章节加载块换成调用 `_maybeStartInitialLoad()`：

```dart
        _controller = controller;
        // ...（保留 assert 调试钩子块不动）
        _maybeStartInitialLoad();
```

把原 `_startContentReadyTimeout()` 移进 `_maybeStartInitialLoad`（只在真正开始加载时启动超时），并把 `:1738-1752` 的歌词/章节分支整体搬入新方法。

(4) 新增方法（放在 `_loadChapterDirectly` 附近）：

```dart
  /// 首章加载需"controller 就绪 ∧ 数据就绪（音频槽/恢复位置已定）"两信号都到。
  /// onWebViewCreated 与 _initBook 尾部各调一次，后到者触发，幂等。
  void _maybeStartInitialLoad() {
    if (_initialLoadStarted) return;
    if (_controller == null || !_audioSlotResolved) return;
    _initialLoadStarted = true;
    _startContentReadyTimeout();
    if (_lyricsMode && _audiobookController != null) {
      final List<AudioCue> allCues = _audiobookController!.allBookCuesSnapshot;
      if (allCues.isNotEmpty) {
        _audiobookController!.setChapterCues(allCues);
      }
      _lyricsEntryChapter = _currentChapter;
      _lyricsEntryCueIndex = allCues.isNotEmpty
          ? _audiobookController!.allBookCueIdx
          : _audiobookController!.currentCueIdx;
      _loadLyricsPage();
    } else {
      _restoreInFlight = true;
      _loadChapterDirectly(_currentChapter);
    }
  }
```

(5) `_initBook` 尾部（`:440-442`）：

```dart
    _audioSlotResolved = true;
    setState(() {});
    _maybeStartInitialLoad();
```

(6) 在 `_initBook` 提前 `return`（`!mounted` 等）后无需调用——未挂载就不加载。`dispose` 时若已 `_initialLoadStarted` 维持原清理路径不变。

- [ ] **Step B2.4：运行 B2 测试 + 全量**

Run: `cd hibiki && dart format . && flutter analyze && flutter test test/pages/reader_open_sequencing_test.dart && flutter test`
Expected: 时序测试 PASS；全量绿。

- [ ] **Step B2.5：Windows 桌面集成冒烟（离屏）**

Run（项目离屏集成方式）：`hibiki/tool/run_windows_itest.ps1`（跑桌面冒烟，确认真 app 打开书不崩、正文可见、焦点遍历正常）。留证据。

- [ ] **Step B2.6：提交**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/test/pages/reader_open_sequencing_test.dart
git commit -m "perf(reader): mount WebView before audio-slot resolves, gate first load on both signals"
```

- [ ] **Step B2.7：Windows 真机时延复测（用户）**

同 A.8，对比 A+B1 与 A+B1+B2 的"点击→正文可见"耗时，确认 B2 是否带来可感知提升。

---

## 不在本计划内（后续可选）

- **C（图多书首屏渐进显示）**：`reader_pagination_scripts.dart:1019` 的 `Promise.all(imagePromises)` 让首屏揭示等本章**全部图片**解码完。对漫画/固定布局书是大头，但属行为改动（可能引入布局抖动），且与"打开文字书慢"不同问题，单独立项。
- **Windows 资源拦截字节双拷贝**（`web_resource_response.cpp:36,48` + `*` filter + deferral）：结构性 fork 开销，改动面大、风险高，非首选。

---

## Self-Review 检查

- **Spec 覆盖**：A=桌面预热（根因：`main.dart:196` mobile-only gate）✓；B1=单趟 isolate（根因：两趟 compute 二次整书拷贝）✓；B2=解耦 WebView 挂载与首章加载（根因：`_buildBody:1202` 被 `_audioSlotResolved` 门控）✓。
- **占位扫描**：测试夹具处明确标注"复用 `test/epub`/`test/pages` 现状"，非 TODO；执行者据现有夹具补全，不新造体系。
- **类型一致**：`ParsedBookData`/`parseAndCountChapters`（B1）、`_initialLoadStarted`/`_maybeStartInitialLoad`（B2）命名前后一致；`shouldPrewarmWebView` 签名一致。
- **风险**：A 低（隔离 main.dart + 纯函数测试）；B1 低（等价性单测守卫）；B2 中（动核心时序，靠决策门 + 时序 widget 测试 + 离屏冒烟 + 真机复测兜底，且置于 A 之后边际风险可控）。
