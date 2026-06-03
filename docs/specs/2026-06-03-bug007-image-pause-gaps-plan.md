# BUG-007 图片暂停 — 补两个缺口 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让有声书「遇到图片暂停」对 **sasayaki 型有声书** 也生效，并在暂停时 **把视口滚到那张插图**（否则停了也看不到图）。

**Architecture:** 并发 agent 已修好选择器型 cue（`__hoshiHighlight` 用 `compareDocumentPosition` 判定上一句↔本句锚点之间是否夹 img/svg，命中即 `onImageDetected`，提交 `f0f36588c`）。本计划在其基础上：①把同一套「锚点间检测」抽成共享 JS helper 并接到 sasayaki 高亮路径（`__hoshiHighlightSasayakiCueById`）；②命中插图且需 reveal 时，先把视口滚到插图（而非插图后那句），暂停结束后由控制器 `snapReaderToAudio()` 把视口拉回当前 cue 续播。不重新引入 IntersectionObserver。

**Tech Stack:** Flutter 3.44.0 / Dart；`flutter_inappwebview`（WebView 内 JS）；just_audio；`flutter drive` 集成测试（模拟器 emulator-5554）。

**关键不变量（必须保住，否则破坏已提交的回归/设备测试）：**
- `audiobook_bridge.dart` 源码仍须含：`window.__hoshiPrevHighlight`、`compareDocumentPosition`、`querySelectorAll('img, svg')`、`callHandler('onImageDetected')`；且 **不得** 含 `new IntersectionObserver(` 或 `__hoshiImageObserver`（`test/media/audiobook/image_pause_detection_test.dart` 守这些）。
- `onImageDetected` 必须在 **跨过插图时无条件触发**，与 `reveal` 真假无关（已提交的设备测试 `integration_test/image_pause_detection_test.dart` 用 `reveal=false` 驱动 s1→s2 仍期望触发）。**只有「滚到插图」这一步**才门控在 `reveal===true`。

---

## File Structure

- `hibiki/lib/src/media/audiobook/audiobook_bridge.dart` — 改 `_highlightFn`（抽共享 helper + 改 `__hoshiHighlight`）；改 `_sasayakiFn`（加 `__hoshiSasayakiAnchorEl` + 改 `__hoshiHighlightSasayakiCueById`）。
- `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` — 改 `triggerImagePause`：恢复时 `snapReaderToAudio()` 把视口拉回当前 cue。
- `hibiki/test/media/audiobook/image_pause_detection_test.dart` — 扩源码扫描守卫（sasayaki 路径 + reveal-image + 共享 helper）。
- `hibiki/integration_test/image_pause_detection_test.dart` — 扩设备测试：①选择器路径命中插图且 reveal=true 时 reveal 目标是插图；②sasayaki 路径（stub `hoshiReader`）跨插图触发 `onImageDetected`。
- `packages/hibiki_audio/test/audiobook/image_pause_resume_reveal_test.dart` — 新建：控制器源码扫描守卫，`triggerImagePause` 恢复支调 `snapReaderToAudio`。

---

## Task 1: 抽共享 helper + 选择器路径暂停时滚到插图

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/audiobook_bridge.dart`（`_highlightFn`，当前 46-89 行）
- Test: `hibiki/integration_test/image_pause_detection_test.dart`、`hibiki/test/media/audiobook/image_pause_detection_test.dart`

- [ ] **Step 1: 先扩设备测试（失败用例）——选择器路径命中插图、reveal=true 时 reveal 目标应是插图**

在 `hibiki/integration_test/image_pause_detection_test.dart` 给现有 svg 加 `id="pic"`，并新增一个 testWidgets（与现有同结构，stub 一个能记录 reveal 目标的 `window.hoshiReader.scrollToTarget`）：

```dart
  testWidgets('selector cue: crossing an image reveals the IMAGE (not next text) when reveal=true',
      (WidgetTester tester) async {
    final Completer<void> driven = Completer<void>();
    String? revealTarget;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html), // html 的 svg 需带 id="pic"
          onWebViewCreated: (InAppWebViewController controller) {
            controller.addJavaScriptHandler(
              handlerName: 'reportReveal',
              callback: (List<dynamic> args) {
                revealTarget = args.isNotEmpty ? args.first as String? : null;
                return null;
              },
            );
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            // stub hoshiReader.scrollToTarget 记录 reveal 目标（id 优先）。
            await controller.evaluateJavascript(source:
                "window.hoshiReader={scrollToTarget:function(t){"
                "window.flutter_inappwebview.callHandler('reportReveal',"
                "(t&&(t.id||t.tagName))||null);}};");
            await AudiobookBridge.inject(controller);
            await controller.evaluateJavascript(
                source: "window.__hoshiHighlight('[data-hoshi-sid=s1]', true);");
            await controller.evaluateJavascript(
                source: "window.__hoshiHighlight('[data-hoshi-sid=s2]', true);");
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(revealTarget, 'pic',
        reason: 'cue 推进跨过插图、reveal=true 时应把视口滚到插图(id=pic)而非 s2 文字');
  });
```

并把文件顶部 `html` 常量里的 svg 改成带 id：`<svg id="pic" ...>`。

- [ ] **Step 2: 跑设备测试确认失败**

Run（模拟器在线）：
```bash
cd hibiki && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/image_pause_detection_test.dart -d emulator-5554
```
Expected: 新用例 FAIL（当前 `__hoshiHighlight` 命中插图后 reveal 的是 s2，不是 `pic`；`revealTarget` 会是 `s2` 或文本节点）。原有用例仍 PASS。

- [ ] **Step 3: 实现——把 `_highlightFn` 改成共享 helper + reveal 插图**

把 `audiobook_bridge.dart` 的 `_highlightFn`（46-89 行）整体替换为：

```dart
  /// 高亮 + 图片暂停检测（cue 推进锚点间 DOM 判定，绕开 IntersectionObserver 视口
  /// 可见性 —— 阅读器多栏 overflow:hidden scrollLeft 离散翻页会把整页插图一帧跳过，
  /// IO 永不达阈值，故历史上图片暂停一直无效，见 BUG-007）。
  static const String _highlightFn = '''
window.__hoshiImageBetween = function(prev, el) {
  if (!prev || !el || prev === el || !document.contains(prev)) return null;
  var a = prev, b = el;
  if (prev.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) {
    a = el; b = prev;
  }
  var media = document.querySelectorAll('img, svg');
  for (var i = 0; i < media.length; i++) {
    var m = media[i];
    if ((a.compareDocumentPosition(m) & Node.DOCUMENT_POSITION_FOLLOWING) &&
        (b.compareDocumentPosition(m) & Node.DOCUMENT_POSITION_PRECEDING)) {
      return m;
    }
  }
  return null;
};

window.__hoshiRevealTarget = function(t) {
  if (!t) return;
  if (window.hoshiReader && window.hoshiReader.scrollToTarget) {
    window.hoshiReader.scrollToTarget(t);
  } else {
    t.scrollIntoView({block: 'center', behavior: 'instant'});
  }
};

// cue 推进核心：把上一句锚点更新到 el；若两锚点之间跨过 img/svg → 通知 Dart 暂停。
// 当 reveal 为真时把视口滚到那张插图（而非 el），返回 true 表示「已 reveal 图片，
// 调用方不要再 reveal el」。onImageDetected 与 reveal 无关，跨图就发（设备测试契约）。
window.__hoshiImagePauseAdvance = function(el, reveal) {
  var crossed = window.__hoshiImageBetween(window.__hoshiPrevHighlight, el);
  window.__hoshiPrevHighlight = el;
  if (!crossed) return false;
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('onImageDetected');
  }
  if (reveal) {
    window.__hoshiRevealTarget(crossed);
    return true;
  }
  return false;
};

window.__hoshiHighlight = function(selector, reveal) {
  if (reveal === undefined) reveal = true;
  document.querySelectorAll('.hoshi-active').forEach(function(e) {
    e.classList.remove('hoshi-active');
  });
  if (!selector) { window.__hoshiPrevHighlight = null; return; }
  var el = document.querySelector(selector);
  if (!el) return;
  var revealedImage = window.__hoshiImagePauseAdvance(el, reveal);
  el.classList.add('hoshi-active');
  if (reveal && !revealedImage) {
    window.__hoshiRevealTarget(el);
  }
};
''';
```

- [ ] **Step 4: 跑设备测试确认通过**

Run: 同 Step 2。
Expected: 两个 selector 用例都 PASS（`onImageDetected` 仍触发；`revealTarget == 'pic'`）。

- [ ] **Step 5: 扩源码扫描守卫**

在 `hibiki/test/media/audiobook/image_pause_detection_test.dart` 末尾 `main()` 内追加：

```dart
  test('shared cue-advance helper reveals the crossed image (BUG-007 gap2)', () {
    expect(src, contains('window.__hoshiImagePauseAdvance'),
        reason: 'cue 推进检测抽成共享 helper，selector/sasayaki 两路径复用');
    expect(src, contains('window.__hoshiRevealTarget'),
        reason: '命中插图、reveal 时须把视口滚到插图（否则暂停看不到图）');
  });
```

- [ ] **Step 6: analyze + 静态测试**

Run:
```bash
cd hibiki && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter analyze lib/src/media/audiobook/audiobook_bridge.dart
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/media/audiobook/image_pause_detection_test.dart
```
Expected: analyze 无新错误；source-scan 全过。

- [ ] **Step 7: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/media/audiobook/audiobook_bridge.dart \
        hibiki/integration_test/image_pause_detection_test.dart \
        hibiki/test/media/audiobook/image_pause_detection_test.dart
git commit -m "fix(audiobook): reveal the crossed image before pausing, not the next text (BUG-007 gap2 selector)"
```

---

## Task 2: 把跨图检测接到 sasayaki cue 高亮路径

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/audiobook_bridge.dart`（`_sasayakiFn` 的 `__hoshiHighlightSasayakiCueById`，当前 157-163 行；同块新增 `__hoshiSasayakiAnchorEl`）
- Test: `hibiki/integration_test/image_pause_detection_test.dart`、`hibiki/test/media/audiobook/image_pause_detection_test.dart`

- [ ] **Step 1: 先扩设备测试（失败用例）——sasayaki 跨图触发 onImageDetected**

在 `integration_test/image_pause_detection_test.dart` 新增（stub 一个最小 `hoshiReader`，含 `cueRangesMap`、`highlightSasayakiCue`、`scrollToTarget`）：

```dart
  testWidgets('sasayaki cue: advancing across an image fires onImageDetected (BUG-007 gap1)',
      (WidgetTester tester) async {
    bool imageDetected = false;
    String? revealTarget;
    final Completer<void> driven = Completer<void>();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html), // 复用：c1 span / svg#pic / c2 span
          onWebViewCreated: (InAppWebViewController controller) {
            controller.addJavaScriptHandler(
              handlerName: 'onImageDetected',
              callback: (List<dynamic> _) { imageDetected = true; return null; },
            );
            controller.addJavaScriptHandler(
              handlerName: 'reportReveal',
              callback: (List<dynamic> a) {
                revealTarget = a.isNotEmpty ? a.first as String? : null; return null;
              },
            );
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            // 最小 hoshiReader stub：CSS-highlights 路径 + cueRangesMap + 记录 reveal。
            await controller.evaluateJavascript(source: '''
              window.__hoshiCssHighlightsSupported = true;
              window.hoshiReader = {
                cueRangesMap: new Map(),
                activeCueId: null,
                highlightSasayakiCue: function(id, reveal){ this.activeCueId = id; },
                scrollToTarget: function(t){
                  window.flutter_inappwebview.callHandler('reportReveal',
                    (t && (t.id || t.tagName)) || null);
                }
              };
              (function(){
                function rng(sel){ var el=document.querySelector(sel);
                  var r=document.createRange(); r.selectNodeContents(el); return r; }
                window.hoshiReader.cueRangesMap.set('c1', [rng('[data-hoshi-sid=s1]')]);
                window.hoshiReader.cueRangesMap.set('c2', [rng('[data-hoshi-sid=s2]')]);
              })();
            ''');
            await AudiobookBridge.inject(controller);
            await controller.evaluateJavascript(
                source: "window.__hoshiHighlightSasayakiCueById('c1', false);");
            await controller.evaluateJavascript(
                source: "window.__hoshiHighlightSasayakiCueById('c2', true);");
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(imageDetected, isTrue,
        reason: 'sasayaki cue 从 s1 跨过 svg 推进到 s2 必须触发 onImageDetected');
    expect(revealTarget, 'pic',
        reason: 'sasayaki 跨图、reveal=true 时也应把视口滚到插图');
  });
```

- [ ] **Step 2: 跑设备测试确认失败**

Run: 同 Task1 Step2。
Expected: 新 sasayaki 用例 FAIL（当前 `__hoshiHighlightSasayakiCueById` 无任何跨图检测，`imageDetected` 仍为 false）。

- [ ] **Step 3: 实现——`_sasayakiFn` 加锚点 helper + 改 `__hoshiHighlightSasayakiCueById`**

把 `__hoshiHighlightSasayakiCueById`（157-163 行）替换为下面两段（`__hoshiSasayakiAnchorEl` 紧贴其前）：

```dart
window.__hoshiSasayakiAnchorEl = function(key) {
  var r = window.hoshiReader;
  if (!r) return null;
  if (window.__hoshiCssHighlightsSupported && r.cueRangesMap && r.cueRangesMap.get) {
    var ranges = r.cueRangesMap.get(key);
    if (ranges && ranges[0]) {
      var n = ranges[0].startContainer;
      return n && n.nodeType === 1 ? n : (n ? n.parentElement : null);
    }
  } else if (r.cueWrappers && r.cueWrappers.get) {
    var w = r.cueWrappers.get(key);
    if (w && w[0]) return w[0];
  }
  return null;
};

window.__hoshiHighlightSasayakiCueById = function(key, reveal) {
  if (reveal === undefined) reveal = true;
  var r = window.hoshiReader;
  if (!r || typeof r.highlightSasayakiCue !== 'function') return false;
  var anchor = window.__hoshiSasayakiAnchorEl(key);
  var revealedImage = false;
  if (anchor && typeof window.__hoshiImagePauseAdvance === 'function') {
    revealedImage = window.__hoshiImagePauseAdvance(anchor, reveal);
  }
  // 跨过插图且需 reveal 时：让 reader 只高亮不自动滚（已滚到插图）；否则正常 reveal。
  r.highlightSasayakiCue(key, revealedImage ? false : reveal);
  return true;
};
```

- [ ] **Step 4: 跑设备测试确认通过**

Run: 同 Task1 Step2。
Expected: 全部用例 PASS（selector + sasayaki 都触发；reveal 目标都是 `pic`）。

- [ ] **Step 5: 扩源码扫描守卫（sasayaki 路径已接检测）**

在 `test/media/audiobook/image_pause_detection_test.dart` 追加：

```dart
  test('sasayaki cue path is wired to image-pause detection (BUG-007 gap1)', () {
    expect(src, contains('window.__hoshiSasayakiAnchorEl'),
        reason: 'sasayaki cue 须能解析锚点元素（cueRangesMap/cueWrappers）');
    expect(src, contains('cueRangesMap'),
        reason: 'CSS-highlights 路径从 cueRangesMap 取 sasayaki cue 的 range 锚点');
    // __hoshiHighlightSasayakiCueById 必须调共享核心做跨图检测。
    final int sasIdx = src.indexOf('__hoshiHighlightSasayakiCueById = function');
    expect(sasIdx, greaterThan(-1));
    final String sasFn = src.substring(sasIdx, sasIdx + 600);
    expect(sasFn, contains('__hoshiImagePauseAdvance'),
        reason: 'sasayaki 高亮路径须复用共享跨图检测核心');
  });
```

- [ ] **Step 6: analyze + 静态测试** — 同 Task1 Step6。

- [ ] **Step 7: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/media/audiobook/audiobook_bridge.dart \
        hibiki/integration_test/image_pause_detection_test.dart \
        hibiki/test/media/audiobook/image_pause_detection_test.dart
git commit -m "fix(audiobook): detect image-crossing on sasayaki cue path too (BUG-007 gap1)"
```

---

## Task 3: 暂停结束后把视口拉回当前 cue（续播 audio-follow）

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`（`triggerImagePause`，当前 214-227 行）
- Test: `packages/hibiki_audio/test/audiobook/image_pause_resume_reveal_test.dart`（新建）

- [ ] **Step 1: 先写源码扫描守卫（失败用例）**

新建 `packages/hibiki_audio/test/audiobook/image_pause_resume_reveal_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-007 gap2 续播守卫：图片暂停结束恢复播放后，必须把视口从插图拉回当前 cue
/// （插图后那句），否则 reveal 停在插图上、audio-follow 对不上当前句。
void main() {
  final String src = File(
    'lib/src/audiobook/audiobook_controller.dart',
  ).readAsStringSync();

  test('triggerImagePause resume re-reveals current cue via snapReaderToAudio', () {
    final int idx = src.indexOf('void triggerImagePause()');
    expect(idx, greaterThan(-1), reason: 'triggerImagePause 必须存在');
    // 取函数体到下一个方法声明前的片段。
    final int end = src.indexOf('\n  /// ', idx);
    final String body = src.substring(idx, end > idx ? end : idx + 800);
    expect(body, contains('snapReaderToAudio'),
        reason: '恢复播放后须 snapReaderToAudio() 把视口拉回当前 cue');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd packages/hibiki_audio && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/audiobook/image_pause_resume_reveal_test.dart
```
Expected: FAIL（当前 `triggerImagePause` 恢复支只 `notifyListeners()`，无 `snapReaderToAudio`）。

- [ ] **Step 3: 实现——恢复支改调 snapReaderToAudio**

把 `triggerImagePause`（214-227 行）的 Timer 恢复支：

```dart
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      _imagePauseTimer = null;
      if (!_player.playing) {
        unawaited(_player.play());
        notifyListeners();
      }
    });
```

改为：

```dart
    _imagePauseTimer = Timer(Duration(seconds: sec), () {
      _imagePauseTimer = null;
      if (!_player.playing) {
        unawaited(_player.play());
        // 暂停时视口停在插图上；恢复后把视口拉回当前 cue（插图后那句），
        // 让 reader 的 _onCueChanged 以 forceReveal 续上 audio-follow。
        snapReaderToAudio();
      }
    });
```

（`snapReaderToAudio()` 已 `notifyListeners()`，故删掉原恢复支的 `notifyListeners()`。外层暂停时的 `notifyListeners()` 不动。）

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2。Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki
git add packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart \
        packages/hibiki_audio/test/audiobook/image_pause_resume_reveal_test.dart
git commit -m "fix(audiobook): re-reveal current cue after image-pause resume (BUG-007 gap2)"
```

---

## Task 4: 全量验证 + 设备复测原始失败路径

- [ ] **Step 1: analyze + 单测全量**

```bash
cd hibiki && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter analyze
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/media/audiobook/
cd ../packages/hibiki_audio && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter test
```
Expected: analyze 无新错误；audiobook 单测全绿（含并发 agent 既有 260 项无回归）。

- [ ] **Step 2: 设备测试（bare WebView 行为）**

```bash
cd hibiki && /d/flutter_sdk/flutter_extracted/flutter/bin/flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/image_pause_detection_test.dart -d emulator-5554
```
Expected: 全部用例 PASS（selector + sasayaki 触发；reveal 目标 `pic`）。

- [ ] **Step 3: 真实有声书端到端复测（必做，reader 类纪律）**

bare-WebView 测试覆盖不到「真实分页 + scrollIntoView 在多栏 overflow:hidden 下把插图正确成页、暂停结束后翻页不漂移」。需用真实有声书（带整页插图 + 音频）在 emulator-5554 实跑：
- 打开一本带插图的有声书，开启「遇到图片暂停 5s」，播放到插图处。
- 观察：到插图时是否**滚到插图并暂停约 5s**；恢复后是否回到插图后正文继续、**翻页对齐无漂移**（对照 `reader_pagination_test` 的 I1/I6 不变量心智）。
- 留证：截图（插图暂停帧 + 恢复后帧）放 `.codex-test/`，记 logcat `onImageDetected` 触发。
- ⚠️ 风险点：若 `scrollIntoView({block:'center'})` 把 body 停在非列距对齐位置导致后续翻页漂移，则把 `__hoshiRevealTarget` 的图片分支改用页对齐 reveal（`hoshiReader.scrollToRange(range.selectNode(img))` 优先，fallback scrollIntoView）。仅在设备实测出现漂移时才改，避免动到既有正常的文本 reveal 路径。

- [ ] **Step 4: 更新 BUG-007 记录（谨慎，BUGS.md 有并发 agent 未提交改动）**

先 `git status --short` 确认 `docs/BUGS.md` 状态；**只在 BUG-007 的「备注」追加**本轮两缺口已补 + 提交哈希 + 设备复测结论，不动 BUG-008 / 其它条目。若该文件仍是并发 agent 未提交状态，先与其协调或仅提交自己的代码/测试，BUG-007 备注更新单独小心 stage。

```bash
cd /d/APP/vs_claude_code/hibiki
git status --short
# 编辑 docs/BUGS.md：仅在 BUG-007 备注追加 gap1/gap2 已补 + 哈希 + 设备结论
git add docs/BUGS.md
git commit -m "docs(bugs): BUG-007 follow-up — sasayaki coverage + reveal-image-on-pause fixed"
```

- [ ] **Step 5: 收尾自检**

`git status --short` 确认只提交了本轮相关文件（禁止 `git add -A`）；回复中给出各提交哈希 + 仍存在的无关未提交改动（并发 agent 的 spec/registrant 等）。

---

## Self-Review

- **Spec 覆盖**：gap1（sasayaki 覆盖）= Task 2；gap2（暂停滚到插图 = Task 1 reveal-image + Task 3 恢复拉回）。✓
- **不变量**：onImageDetected 无条件触发（仅 reveal-image 门控 reveal）→ Task1 Step3 `__hoshiImagePauseAdvance` 先发后判 reveal；保住既有设备测试与源码扫描守卫的全部断言（prevHighlight / compareDocumentPosition / querySelectorAll('img, svg') / 无 IntersectionObserver）。✓
- **类型/命名一致**：JS helper 名贯穿——`__hoshiImageBetween` / `__hoshiRevealTarget` / `__hoshiImagePauseAdvance` / `__hoshiSasayakiAnchorEl` / `__hoshiPrevHighlight`；Dart `snapReaderToAudio()`（已存在，827 行）。✓
- **风险**：gap2 的 `scrollIntoView` 列对齐（Task4 Step3 已列出实测兜底）；sasayaki 设备测试用 stub `hoshiReader`（CSS-highlights 路径），真实 reader 的 sasayaki 端到端仍靠 Task4 Step3 复测。
