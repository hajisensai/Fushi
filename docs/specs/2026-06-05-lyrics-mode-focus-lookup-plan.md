# 歌词模式行级焦点查词 实现计划

> **For agentic workers:** 用 superpowers:subagent-driven-development 或 executing-plans 按 task 执行。步骤用 `- [ ]` 勾选。

**Goal:** 让键盘/手柄在有声书「歌词模式」逐词焦点查词（上下跳 cue 行、左右逐字、A/Enter 查词），激活时暂停播放自动滚动。

**Architecture:** 新增轻量 JS `window.hoshiLyricsCaret`（专用行级 caret，stop 限定在当前 cue 行内，行间移动靠 `data-cue-index` 索引 + 复用 `scrollToCenter`，避免复用 `hoshiCaret` 全文逐字 `_charRect` 的性能问题）。查词复用 `hoshiSelection.selectFromPosition`，输入路由复用 `ReaderCaretRouter`（零改）。Dart 加 `CaretSurface.lyrics` 分支。

**Tech Stack:** Dart/Flutter 3.44.0、flutter_inappwebview、纯 JS 注入字符串、flutter_test。

**设计文档:** `docs/specs/2026-06-05-lyrics-mode-focus-lookup-design.md`

**关键事实（已核验）:**
- `enum CaretSurface { none, reader, popup }` 在 `reader_hibiki_page.dart:64`。
- 歌词文档注入 `ReaderSelectionScripts.source()`（`lyrics_mode_html.dart:36`），故 `hoshiSelection.selectFromPosition / createWalker / clearSelection` 在歌词文档可用。
- 歌词文档已暴露 `window.__lyricsGetCurrentIndex()`（`lyrics_mode_html.dart:184`）、`window.__lyricsSetCue()`、`__lyricsCueContext`（点击查词回路用）。
- 歌词页就绪点：`_onChapterLoadComplete` 的 lyrics 分支（`reader_hibiki_page.dart:2002-2013`），那里 `_readerContentReady=true` 也置位 → `_enterCaret` 的就绪守卫通过。
- `__lyricsSetCue`/`setCue` 做「换高亮 class + `scrollToCenter`」（`lyrics_mode_html.dart:165-180`）。
- **预存红警告**：develop 上有一条与本功能无关、针对 reader_hibiki_page 的 audio-lifecycle 守卫测试可能为红；以 targeted 测试为准，别被它误导。
- **并发工作树**：只 stage 本轮文件，禁 `git add -A`。

---

## File Structure

- **Create** `hibiki/lib/src/reader/reader_lyrics_caret_scripts.dart` — `ReaderLyricsCaretScripts`：`window.hoshiLyricsCaret` JS 源 + invocation builders。
- **Modify** `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart` — `setCue` 滚动受 `window.__lyricsCaretActive` 门控；新增 `window.__lyricsScrollToCue(index)`。
- **Modify** `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` — `CaretSurface.lyrics`；歌词页注入 caret；`_enterCaret/_exitCaret/_caretMove/_caretScrollPage/_caretLookup/_caretActivate/_caretLongPress/_caretRefresh`+ suspend/resume 加 lyrics 分支；退出歌词模式复位 surface。
- **Test** `hibiki/test/reader/reader_lyrics_caret_scripts_test.dart`
- **Test** `hibiki/test/media/audiobook/lyrics_mode_html_caret_test.dart`
- **Test** `hibiki/test/reader/reader_lyrics_caret_wiring_test.dart`

---

## Task 1: `ReaderLyricsCaretScripts`（JS 源 + invocation builders）

**Files:**
- Create: `hibiki/lib/src/reader/reader_lyrics_caret_scripts.dart`
- Test: `hibiki/test/reader/reader_lyrics_caret_scripts_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/reader/reader_lyrics_caret_scripts_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_lyrics_caret_scripts.dart';

void main() {
  group('ReaderLyricsCaretScripts.source()', () {
    final String src = ReaderLyricsCaretScripts.source();

    test('defines the hoshiLyricsCaret object and core API', () {
      expect(src, contains('window.hoshiLyricsCaret'));
      for (final String fn in <String>[
        'enter:', 'exit:', 'move:', 'lookup:', 'activate:',
        'scrollPage:', 'refresh:', 'init:', 'suspend:', 'resume:',
      ]) {
        expect(src, contains(fn), reason: 'missing $fn');
      }
    });

    test('line moves go through cue index + __lyricsScrollToCue', () {
      expect(src, contains('__lyricsScrollToCue'));
      expect(src, contains('__lyricsGetCurrentIndex'));
      expect(src, contains('_lineMove'));
    });

    test('lookup reuses hoshiSelection.selectFromPosition with cue context', () {
      expect(src, contains('window.hoshiSelection'));
      expect(src, contains('selectFromPosition'));
      expect(src, contains('__lyricsCueContext'));
      expect(src, contains('data-text-fragment-id'));
    });
  });

  group('ReaderLyricsCaretScripts invocations target hoshiLyricsCaret', () {
    test('enter/exit/move/scrollPage/lookup/activate/refresh', () {
      expect(ReaderLyricsCaretScripts.enterInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.enter())');
      expect(ReaderLyricsCaretScripts.exitInvocation(),
          'window.hoshiLyricsCaret.exit()');
      expect(ReaderLyricsCaretScripts.moveInvocation('up'),
          "JSON.stringify(window.hoshiLyricsCaret.move('up'))");
      expect(ReaderLyricsCaretScripts.scrollPageInvocation(true),
          'JSON.stringify(window.hoshiLyricsCaret.scrollPage(true))');
      expect(ReaderLyricsCaretScripts.lookupInvocation(),
          'window.hoshiLyricsCaret.lookup()');
      expect(ReaderLyricsCaretScripts.activateInvocation(),
          'window.hoshiLyricsCaret.activate()');
      expect(ReaderLyricsCaretScripts.refreshInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.refresh())');
      expect(ReaderLyricsCaretScripts.suspendInvocation(),
          'window.hoshiLyricsCaret.suspend()');
      expect(ReaderLyricsCaretScripts.resumeInvocation(),
          'JSON.stringify(window.hoshiLyricsCaret.resume())');
      expect(ReaderLyricsCaretScripts.longPressInvocation(),
          'window.hoshiLyricsCaret.longPress()');
    });

    test('initInvocation carries ring color', () {
      final String js = ReaderLyricsCaretScripts.initInvocation(
        color: 'rgba(1,2,3,0.98)',
        insetTop: 10,
        insetBottom: 0,
      );
      expect(js, contains('window.hoshiLyricsCaret.init('));
      expect(js, contains('rgba(1,2,3,0.98)'));
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/reader/reader_lyrics_caret_scripts_test.dart`
Expected: FAIL（`Target of URI doesn't exist` / 类未定义编译错误）。

- [ ] **Step 3: 写实现**

`hibiki/lib/src/reader/reader_lyrics_caret_scripts.dart`:

```dart
/// JavaScript "line caret" for the audiobook **lyrics mode** (`LyricsModeHtml`).
///
/// Lyrics mode is a separate, continuously-scrolled document whose lines are the
/// discrete `.cue` divs. Unlike the paginated reader's [ReaderCaretScripts]
/// (which walks every glyph in the whole DOM and forces a layout per character —
/// far too heavy for a whole-book lyrics document), this caret keeps its stops
/// inside the **current cue** only: Up/Down hop between cue rows by
/// `data-cue-index` (reusing the document's own `__lyricsScrollToCue` to centre
/// the row), Left/Right step character-by-character within the focused cue. Word
/// lookup reuses `window.hoshiSelection.selectFromPosition`, so a caret lookup
/// hits the exact same dictionary pipeline as a tap, with `__lyricsCueContext`
/// set so the favourite/sentence metadata matches the click path.
///
/// Status payloads ({status, rect} / {ok, rect}) are parsed by the generic
/// [ReaderCaretScripts.moveStatus] / [ReaderCaretScripts.rectOf] on the Dart side.
class ReaderLyricsCaretScripts {
  ReaderLyricsCaretScripts._();

  static String enterInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.enter())';

  static String exitInvocation() => 'window.hoshiLyricsCaret.exit()';

  static String suspendInvocation() => 'window.hoshiLyricsCaret.suspend()';

  static String resumeInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.resume())';

  static String moveInvocation(String dir) =>
      "JSON.stringify(window.hoshiLyricsCaret.move('$dir'))";

  static String scrollPageInvocation(bool forward) =>
      'JSON.stringify(window.hoshiLyricsCaret.scrollPage($forward))';

  static String refreshInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.refresh())';

  static String lookupInvocation() => 'window.hoshiLyricsCaret.lookup()';

  static String activateInvocation() => 'window.hoshiLyricsCaret.activate()';

  static String longPressInvocation() => 'window.hoshiLyricsCaret.longPress()';

  static String initInvocation({
    required String color,
    required double insetTop,
    required double insetBottom,
  }) =>
      "window.hoshiLyricsCaret.init({color:'$color',insetTop:$insetTop,"
      'insetBottom:$insetBottom})';

  static String source() => r"""
window.hoshiLyricsCaret = {
  active: false,
  cueIndex: -1,
  node: null,
  offset: 0,
  ringColor: 'rgba(255,138,0,0.98)',
  insetTop: 0,
  insetBottom: 0,
  _ring: null,

  init: function(opts) {
    opts = opts || {};
    if (opts.color) this.ringColor = opts.color;
    if (opts.insetTop != null) this.insetTop = opts.insetTop;
    if (opts.insetBottom != null) this.insetBottom = opts.insetBottom;
    this._applyRingStyle();
    if (this.active) {
      var r = this._anchorRect();
      if (r) this._drawRing(r);
    }
    return true;
  },

  _cues: function() { return document.querySelectorAll('.cue'); },
  _walker: function(root) {
    if (window.hoshiSelection && typeof window.hoshiSelection.createWalker === 'function') {
      return window.hoshiSelection.createWalker(root);
    }
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  },
  _charLen: function(text, i) {
    var cp = text.codePointAt(i);
    return (cp !== undefined && cp > 0xFFFF) ? 2 : 1;
  },
  _prevIndex: function(text, i) {
    if (i <= 0) return -1;
    var j = i - 1;
    if (j > 0) {
      var c = text.charCodeAt(j);
      if (c >= 0xDC00 && c <= 0xDFFF) j -= 1;
    }
    return j;
  },
  _isStop: function(node, offset) {
    var text = node.textContent;
    if (offset < 0 || offset >= text.length) return false;
    if (/^[\s　]$/.test(text[offset])) return false;
    return true;
  },
  _charRect: function(node, offset) {
    var len = this._charLen(node.textContent, offset);
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + len);
    var rects = range.getClientRects();
    if (rects && rects.length) {
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width > 0 && rects[i].height > 0) return rects[i];
      }
    }
    return range.getBoundingClientRect();
  },
  _firstStopInCue: function(cueEl) {
    if (!cueEl) return null;
    var walker = this._walker(cueEl);
    var node;
    while (node = walker.nextNode()) {
      var text = node.textContent;
      for (var i = 0; i < text.length;) {
        if (this._isStop(node, i)) return { node: node, offset: i };
        i += this._charLen(text, i);
      }
    }
    return null;
  },
  _stepInCue: function(forward) {
    var cueEl = this._cues()[this.cueIndex];
    if (!cueEl || !this.node) return null;
    var walker = this._walker(cueEl);
    walker.currentNode = this.node;
    var node = this.node, text = node.textContent, i;
    if (forward) {
      i = this.offset + this._charLen(text, this.offset);
      while (true) {
        while (i < text.length) {
          if (this._isStop(node, i)) return { node: node, offset: i };
          i += this._charLen(text, i);
        }
        var n = walker.nextNode();
        if (!n) return null;
        node = n; text = node.textContent; i = 0;
      }
    } else {
      i = this._prevIndex(text, this.offset);
      while (true) {
        while (i >= 0) {
          if (this._isStop(node, i)) return { node: node, offset: i };
          i = this._prevIndex(text, i);
        }
        var p = walker.previousNode();
        if (!p) return null;
        node = p; text = node.textContent; i = this._prevIndex(text, text.length);
      }
    }
  },

  _applyRingStyle: function() {
    if (!this._ring) return;
    var color = this.ringColor || 'rgba(255,138,0,0.98)';
    this._ring.style.border = '2px solid ' + color;
    this._ring.style.boxShadow = '0 0 0 2px rgba(0,0,0,0.28), 0 0 6px ' + color;
  },
  _ensureRing: function() {
    if (this._ring && this._ring.isConnected) return this._ring;
    var r = document.getElementById('hoshi-lyrics-caret-ring');
    if (!r) {
      r = document.createElement('div');
      r.id = 'hoshi-lyrics-caret-ring';
      r.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;' +
        'box-sizing:border-box;border-radius:3px;display:none;';
      document.documentElement.appendChild(r);
    }
    this._ring = r;
    this._applyRingStyle();
    return r;
  },
  _drawRing: function(rect) {
    var r = this._ensureRing();
    var pad = 1;
    r.style.display = 'block';
    r.style.left = (rect.left - pad) + 'px';
    r.style.top = (rect.top - pad) + 'px';
    r.style.width = (rect.width + pad * 2) + 'px';
    r.style.height = (rect.height + pad * 2) + 'px';
  },
  _hideRing: function() { if (this._ring) this._ring.style.display = 'none'; },
  _rectJson: function(rect) {
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  },
  _anchorRect: function() {
    if (this.node && document.contains(this.node)) return this._charRect(this.node, this.offset);
    return null;
  },
  _place: function(stop) {
    this.node = stop.node; this.offset = stop.offset;
    var rect = stop.rect || this._charRect(stop.node, stop.offset);
    this._drawRing(rect);
    return rect;
  },

  isActive: function() { return !!this.active; },

  enter: function() {
    this._ensureRing();
    var cues = this._cues();
    if (!cues.length) { this.active = false; return { ok: false }; }
    var idx = -1;
    if (typeof window.__lyricsGetCurrentIndex === 'function') {
      idx = window.__lyricsGetCurrentIndex();
    }
    if (idx < 0 || idx >= cues.length) idx = 0;
    var pos = this._firstStopInCue(cues[idx]);
    while (!pos && idx < cues.length - 1) { idx++; pos = this._firstStopInCue(cues[idx]); }
    if (!pos) { this.active = false; return { ok: false }; }
    this.active = true;
    this.cueIndex = idx;
    var rect = this._place(pos);
    return { ok: true, rect: this._rectJson(rect) };
  },

  exit: function() { this.active = false; this._hideRing(); return true; },
  suspend: function() { this._hideRing(); return true; },
  resume: function() {
    if (!this.active) return { ok: false };
    var r = this._anchorRect();
    if (r) { this._drawRing(r); return { ok: true, rect: this._rectJson(r) }; }
    return this.refresh();
  },

  _lineMove: function(forward) {
    var cues = this._cues();
    var next = forward ? this.cueIndex + 1 : this.cueIndex - 1;
    var pos = null;
    while (next >= 0 && next < cues.length) {
      pos = this._firstStopInCue(cues[next]);
      if (pos) break;
      next = forward ? next + 1 : next - 1;
    }
    if (!pos) return { status: 'blocked' };
    this.cueIndex = next;
    if (typeof window.__lyricsScrollToCue === 'function') window.__lyricsScrollToCue(next);
    var rect = this._place(pos);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  move: function(dir) {
    if (!this.active || !this.node) return { status: 'blocked' };
    if (!document.contains(this.node)) {
      var re = this.refresh();
      if (!re.ok) return { status: 'blocked' };
    }
    if (dir === 'up') return this._lineMove(false);
    if (dir === 'down') return this._lineMove(true);
    var forward = (dir === 'right' || dir === 'forward');
    var target = this._stepInCue(forward);
    if (!target) return { status: 'blocked' };
    var rect = this._place(target);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  scrollPage: function(forward) {
    if (!this.active) return { status: 'blocked' };
    var cues = this._cues();
    var STEP = 5;
    var target = forward ? Math.min(cues.length - 1, this.cueIndex + STEP)
                         : Math.max(0, this.cueIndex - STEP);
    var pos = this._firstStopInCue(cues[target]);
    while (!pos && target > 0 && target < cues.length - 1) {
      target = forward ? target + 1 : target - 1;
      pos = this._firstStopInCue(cues[target]);
    }
    if (!pos) return { status: 'blocked' };
    this.cueIndex = target;
    if (typeof window.__lyricsScrollToCue === 'function') window.__lyricsScrollToCue(target);
    var rect = this._place(pos);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  refresh: function() {
    if (!this.active) return { ok: false };
    if (this.node && document.contains(this.node) && this._isStop(this.node, this.offset)) {
      var rect = this._charRect(this.node, this.offset);
      this._drawRing(rect);
      return { ok: true, rect: this._rectJson(rect) };
    }
    var cues = this._cues();
    var pos = (this.cueIndex >= 0 && this.cueIndex < cues.length)
      ? this._firstStopInCue(cues[this.cueIndex]) : null;
    if (!pos) { this._hideRing(); return { ok: false }; }
    var r = this._place(pos);
    return { ok: true, rect: this._rectJson(r) };
  },

  _setCueContext: function() {
    var cueEl = this._cues()[this.cueIndex];
    if (cueEl) {
      window.__lyricsCueContext = {
        textFragmentId: cueEl.getAttribute('data-text-fragment-id'),
        cueIndex: parseInt(cueEl.getAttribute('data-cue-index'), 10)
      };
    } else {
      window.__lyricsCueContext = null;
    }
  },
  lookup: function() {
    if (!this.active || !this.node) return false;
    var s = window.hoshiSelection;
    if (!s || typeof s.selectFromPosition !== 'function') return false;
    this._setCueContext();
    if (typeof s.clearSelection === 'function') s.clearSelection();
    var text = s.selectFromPosition(this.node, this.offset, 400);
    return !!text;
  },
  activate: function() { return this.lookup() ? 'lookup' : 'none'; },
  longPress: function() { return this.lookup() ? 'lookup' : 'none'; }
};
""";
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/reader/reader_lyrics_caret_scripts_test.dart`
Expected: PASS（全部 group 绿）。

- [ ] **Step 5: 提交**

```bash
git -C .. add hibiki/lib/src/reader/reader_lyrics_caret_scripts.dart \
  hibiki/test/reader/reader_lyrics_caret_scripts_test.dart
git -C .. commit -m "feat(reader): add hoshiLyricsCaret line-level caret scripts"
```
（在 `hibiki/` 目录跑 flutter test；git 路径按实际工作区调整，**只 stage 本轮文件**。）

---

## Task 2: 歌词文档 — 跟随抑制 + `__lyricsScrollToCue`

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`
- Test: `hibiki/test/media/audiobook/lyrics_mode_html_caret_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/media/audiobook/lyrics_mode_html_caret_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';

void main() {
  AudioCue cue(int i, String text) => AudioCue(
        sentenceIndex: i,
        text: text,
        startMs: i * 1000,
        endMs: i * 1000 + 900,
        textFragmentId: 'frag-$i',
      );

  String html() => LyricsModeHtml.generate(
        cues: <AudioCue>[cue(0, 'ねこ'), cue(1, 'いぬ'), cue(2, 'とり')],
        currentIndex: 1,
        backgroundColor: 'rgba(0,0,0,1.00)',
        textColor: 'rgba(255,255,255,1.00)',
        accentColor: 'rgba(255,200,0,1.00)',
        fontSize: 24,
      );

  test('exposes __lyricsScrollToCue helper for the caret', () {
    expect(html(), contains('window.__lyricsScrollToCue'));
  });

  test('setCue auto-scroll is gated by __lyricsCaretActive', () {
    // 焦点激活时 setCue 只换高亮、不抢滚动。
    expect(html(), contains('__lyricsCaretActive'));
  });
}
```

> 注：`AudioCue` 构造字段名以 `packages/hibiki_audio` 实际定义为准；若签名不同，按真实字段构造（只需 3 个非空 cue）。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/media/audiobook/lyrics_mode_html_caret_test.dart`
Expected: FAIL（`Expected: contains '__lyricsScrollToCue'`）。

- [ ] **Step 3: 改实现 — setCue 滚动门控**

`lyrics_mode_html.dart`，把 `setCue` 末尾的无条件滚动（当前 `scrollToCenter(_cues[index]);`，约 179 行）改为受标志门控。

old_string:
```
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  scrollToCenter(_cues[index]);
}
```
new_string:
```
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  // 焦点 caret 激活时，播放推进只换高亮，不把屏幕从用户正读的行拽走。
  if (!window.__lyricsCaretActive) scrollToCenter(_cues[index]);
}
```

- [ ] **Step 4: 改实现 — 暴露 __lyricsScrollToCue**

在 `window.__lyricsGetCurrentIndex` 定义之后（约 184 行）追加。

old_string:
```
// ── Dart bridge ──
window.__lyricsSetCue = function(index) { setCue(index); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };
```
new_string:
```
// ── Dart bridge ──
window.__lyricsSetCue = function(index) { setCue(index); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };
// 供 hoshiLyricsCaret 行间移动时把目标 cue 居中（复用同一滚动动画）。
window.__lyricsScrollToCue = function(index) {
  if (index >= 0 && index < _cues.length) scrollToCenter(_cues[index]);
};
```

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/media/audiobook/lyrics_mode_html_caret_test.dart`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git -C .. add hibiki/lib/src/media/audiobook/lyrics_mode_html.dart \
  hibiki/test/media/audiobook/lyrics_mode_html_caret_test.dart
git -C .. commit -m "feat(audiobook): lyrics setCue scroll gate + __lyricsScrollToCue for caret"
```

---

## Task 3: Dart 接线（reader_hibiki_page.dart）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
- Test: `hibiki/test/reader/reader_lyrics_caret_wiring_test.dart`

> 全部用唯一 old_string 锚点匹配（不要依赖行号，并发改动会移动行号）。

- [ ] **Step 1: 加 import**

old_string:
```
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
```
new_string:
```
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_lyrics_caret_scripts.dart';
```

- [ ] **Step 2: 扩 CaretSurface 枚举**

old_string:
```
enum CaretSurface { none, reader, popup }
```
new_string:
```
enum CaretSurface { none, reader, popup, lyrics }
```

- [ ] **Step 3: 加 `_caretOnLyrics` getter**

紧挨现有 `_caretOnReader` getter 之后追加。

old_string:
```
  bool get _caretOnReader => _caretSurface == CaretSurface.reader;
```
new_string:
```
  bool get _caretOnReader => _caretSurface == CaretSurface.reader;
  bool get _caretOnLyrics => _caretSurface == CaretSurface.lyrics;
```

- [ ] **Step 4: suspend/resume 加 lyrics 分支**

old_string:
```
        case CaretSurface.reader:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderCaretScripts.suspendInvocation()
                : ReaderCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.none:
          break;
```
new_string:
```
        case CaretSurface.reader:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderCaretScripts.suspendInvocation()
                : ReaderCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.lyrics:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderLyricsCaretScripts.suspendInvocation()
                : ReaderLyricsCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.none:
          break;
```

- [ ] **Step 5: 歌词页就绪时注入 caret**

old_string:
```
      _lyricsPageReady = true;
      _onCueChanged();
      await _applyLyricsFavorites();
      return;
```
new_string:
```
      _lyricsPageReady = true;
      // 注入歌词专用行级 caret（键盘/手柄逐词查词），镜像 reader 的 hoshiCaret 注入。
      // 文档刚加载，caret inactive；surface 在 _enterCaret 成功时才置 lyrics。
      await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.source());
      if (mounted) {
        await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.initInvocation(
            color: _caretRingColorCss(),
            insetTop: _readerTopOffset,
            insetBottom: 0,
          ),
        );
      }
      _onCueChanged();
      await _applyLyricsFavorites();
      return;
```

- [ ] **Step 6: `_enterCaret` 加 lyrics 分支**

old_string:
```
    _caretBusy = true;
    try {
      final Object? raw = await _controller!
          .evaluateJavascript(source: ReaderCaretScripts.enterInvocation());
      if (!mounted) return;
      // enter() returns {ok:false} on an empty page (no visible character).
      if (ReaderCaretScripts.moveStatus(raw) != 'moved') return;
      setState(() => _caretSurface = CaretSurface.reader);
    } finally {
      _caretBusy = false;
    }
```
new_string:
```
    _caretBusy = true;
    try {
      final Object? raw = await _controller!.evaluateJavascript(
          source: _lyricsMode
              ? ReaderLyricsCaretScripts.enterInvocation()
              : ReaderCaretScripts.enterInvocation());
      if (!mounted) return;
      // enter() returns {ok:false} on an empty page (no visible character).
      if (ReaderCaretScripts.moveStatus(raw) != 'moved') return;
      if (_lyricsMode) {
        // 激活后暂停播放跟随滚动：setCue 只换高亮，不抢滚动。
        await _controller!.evaluateJavascript(
            source: 'window.__lyricsCaretActive = true;');
        setState(() => _caretSurface = CaretSurface.lyrics);
      } else {
        setState(() => _caretSurface = CaretSurface.reader);
      }
    } finally {
      _caretBusy = false;
    }
```

- [ ] **Step 7: `_exitCaret` 加 lyrics 分支（恢复跟随）**

old_string:
```
      case CaretSurface.reader:
        _controller?.evaluateJavascript(
            source: ReaderCaretScripts.exitInvocation());
        break;
      case CaretSurface.popup:
        topPopupState?.caretExit();
        break;
```
new_string:
```
      case CaretSurface.reader:
        _controller?.evaluateJavascript(
            source: ReaderCaretScripts.exitInvocation());
        break;
      case CaretSurface.lyrics:
        _controller?.evaluateJavascript(
            source: ReaderLyricsCaretScripts.exitInvocation());
        // 退出焦点：恢复播放跟随并立即回到当前播放行。
        _controller?.evaluateJavascript(
            source: 'window.__lyricsCaretActive = false;');
        break;
      case CaretSurface.popup:
        topPopupState?.caretExit();
        break;
```

- [ ] **Step 8: `_caretMove` 加 lyrics（左右逐字/上下跳行）**

old_string:
```
    if (_controller == null) return;
    final Object? raw = await _controller!.evaluateJavascript(
        source: ReaderCaretScripts.moveInvocation(physicalDir));
    if (!mounted || _controller == null) return;
    final String status = ReaderCaretScripts.moveStatus(raw);
    if (status == 'pageForward') {
      await _paginate(ReaderNavigationDirection.forward);
    } else if (status == 'pageBackward') {
      await _paginate(ReaderNavigationDirection.backward);
    }
  }
```
new_string:
```
    if (_controller == null) return;
    final Object? raw = await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.moveInvocation(physicalDir)
            : ReaderCaretScripts.moveInvocation(physicalDir));
    if (!mounted || _controller == null) return;
    // lyrics caret 只返回 moved/blocked，永不 pageForward/Backward，故下面分支天然跳过。
    final String status = ReaderCaretScripts.moveStatus(raw);
    if (status == 'pageForward') {
      await _paginate(ReaderNavigationDirection.forward);
    } else if (status == 'pageBackward') {
      await _paginate(ReaderNavigationDirection.backward);
    }
  }
```

- [ ] **Step 9: `_caretScrollPage` 加 lyrics**

old_string:
```
      if (_controller == null) return;
      final Object? raw = await _controller!.evaluateJavascript(
          source: ReaderCaretScripts.scrollPageInvocation(forward));
      if (!mounted || _controller == null) return;
      final String status = ReaderCaretScripts.moveStatus(raw);
      if (status == 'pageForward') {
        await _paginate(ReaderNavigationDirection.forward);
      } else if (status == 'pageBackward') {
        await _paginate(ReaderNavigationDirection.backward);
      }
```
new_string:
```
      if (_controller == null) return;
      final Object? raw = await _controller!.evaluateJavascript(
          source: _caretOnLyrics
              ? ReaderLyricsCaretScripts.scrollPageInvocation(forward)
              : ReaderCaretScripts.scrollPageInvocation(forward));
      if (!mounted || _controller == null) return;
      final String status = ReaderCaretScripts.moveStatus(raw);
      if (status == 'pageForward') {
        await _paginate(ReaderNavigationDirection.forward);
      } else if (status == 'pageBackward') {
        await _paginate(ReaderNavigationDirection.backward);
      }
```

- [ ] **Step 10: `_caretLookup` 加 lyrics**

old_string:
```
    if (_controller == null) return;
    await _controller!
        .evaluateJavascript(source: ReaderCaretScripts.lookupInvocation());
  }
```
new_string:
```
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.lookupInvocation()
            : ReaderCaretScripts.lookupInvocation());
  }
```

- [ ] **Step 11: `_caretActivate` 加 lyrics**

old_string:
```
    if (_controller == null) return;
    await _controller!
        .evaluateJavascript(source: ReaderCaretScripts.activateInvocation());
  }
```
new_string:
```
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.activateInvocation()
            : ReaderCaretScripts.activateInvocation());
  }
```

- [ ] **Step 12: `_caretLongPress` 加 lyrics**

old_string:
```
    if (_controller == null) return;
    await _controller!
        .evaluateJavascript(source: ReaderCaretScripts.longPressInvocation());
  }
```
new_string:
```
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.longPressInvocation()
            : ReaderCaretScripts.longPressInvocation());
  }
```

- [ ] **Step 13: `_caretRefresh` 支持 lyrics**

old_string:
```
  Future<void> _caretRefresh() async {
    if (!_caretOnReader || _controller == null) return;
    await _controller!
        .evaluateJavascript(source: ReaderCaretScripts.refreshInvocation());
  }
```
new_string:
```
  Future<void> _caretRefresh() async {
    if (_controller == null || (!_caretOnReader && !_caretOnLyrics)) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.refreshInvocation()
            : ReaderCaretScripts.refreshInvocation());
  }
```

- [ ] **Step 14: 退出歌词模式时复位 caret surface**

`_exitLyricsMode` 开头（在 `final AudiobookPlayerController ctrl = ...` 之前）加复位：离开歌词模式会重载 reader 章节，歌词 caret JS 随之消失，surface 必须归 none，否则后续输入被误路由到不存在的 lyrics caret。

old_string:
```
  Future<void> _exitLyricsMode() async {
    final AudiobookPlayerController ctrl = _audiobookController!;
```
new_string:
```
  Future<void> _exitLyricsMode() async {
    // 离开歌词模式会重载 reader 章节，lyrics caret JS 随之消失；复位 surface，
    // 否则方向键/A 会被误路由到已不存在的 hoshiLyricsCaret。
    if (_caretSurface == CaretSurface.lyrics) {
      setState(() => _caretSurface = CaretSurface.none);
    }
    final AudiobookPlayerController ctrl = _audiobookController!;
```

- [ ] **Step 15: 写源码扫描守卫测试**

`hibiki/test/reader/reader_lyrics_caret_wiring_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test('CaretSurface has a lyrics value', () {
    expect(src, contains('enum CaretSurface { none, reader, popup, lyrics }'));
  });

  test('lyrics page load injects the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.source()'));
    expect(src, contains('ReaderLyricsCaretScripts.initInvocation('));
  });

  test('enter/exit toggle the playback-follow suppression flag', () {
    expect(src, contains("window.__lyricsCaretActive = true;"));
    expect(src, contains("window.__lyricsCaretActive = false;"));
  });

  test('caret actions branch to the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.moveInvocation'));
    expect(src, contains('ReaderLyricsCaretScripts.lookupInvocation'));
    expect(src, contains('_caretOnLyrics'));
  });

  test('leaving lyrics mode resets the caret surface', () {
    expect(src, contains('if (_caretSurface == CaretSurface.lyrics)'));
  });
}
```

- [ ] **Step 16: 跑守卫测试 + 编译**

Run: `flutter test test/reader/reader_lyrics_caret_wiring_test.dart`
Expected: PASS。
Run: `flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart lib/src/reader/reader_lyrics_caret_scripts.dart lib/src/media/audiobook/lyrics_mode_html.dart`
Expected: No issues（除既有无关告警）。

- [ ] **Step 17: 提交**

```bash
git -C .. add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart \
  hibiki/test/reader/reader_lyrics_caret_wiring_test.dart
git -C .. commit -m "feat(reader): wire lyrics-mode focus word lookup (CaretSurface.lyrics)"
```

---

## Task 4: 全量验证 + 收尾

- [ ] **Step 1: 格式化**

Run: `dart format lib/src/reader/reader_lyrics_caret_scripts.dart lib/src/media/audiobook/lyrics_mode_html.dart lib/src/pages/implementations/reader_hibiki_page.dart test/reader/reader_lyrics_caret_scripts_test.dart test/media/audiobook/lyrics_mode_html_caret_test.dart test/reader/reader_lyrics_caret_wiring_test.dart`

- [ ] **Step 2: 跑本功能相关测试 + 全量**

Run（先 targeted）:
`flutter test test/reader/reader_lyrics_caret_scripts_test.dart test/reader/reader_lyrics_caret_wiring_test.dart test/media/audiobook/lyrics_mode_html_caret_test.dart`
Expected: 全绿。

Run（全量）: `flutter test`
Expected: 绿（**预存红**：若有与本功能无关的 reader audio-lifecycle 守卫为红，记录并对照 develop 基线确认非本次引入）。

- [ ] **Step 3: 若 format 改了生成/无关文件**

只 stage 本轮 3 个源文件 + 3 个测试文件的 format 结果；若 `dart format` 顺手改了别的文件，**不要** stage（并发 agent 的）。必要时 `git -C .. add -p` 精确挑本轮 hunk。

- [ ] **Step 4: 提交 format（如有）**

```bash
git -C .. add <本轮文件>
git -C .. commit -m "style(reader): dart format lyrics caret files"
```

- [ ] **Step 5: code review**

按项目规则 spawn code-reviewer subagent，**显式 `model: "opus"`**，审：是否符合设计、边界（空 cue / 单字 cue / 退出时机 / 跟随抑制不影响退出后首次居中）、向后兼容（inactive 路径零改动）、并发 staging 纪律。审出问题修复后重审。

- [ ] **Step 6: 设备验证（留给用户）**

按 `docs/agent/integration-testing.md` 焦点驱动：歌词模式下键盘 + 手柄：A 进入 → 左右逐字移动焦点环 → 上下跳 cue 行（屏幕居中切换、播放推进不抢滚动）→ A 查词命中词典浮层 → B 退出（恢复跟随、回到播放行）。三端（模拟器 / Windows 离屏 / Mac 跨机）。**真机复测留给用户/指定设备**，留证据。

---

## Self-Review（计划对照 spec）

- **spec §4.1 hoshiLyricsCaret** → Task 1（enter/exit/move 行+字/lookup/scrollPage/refresh/init/suspend/resume 全覆盖）。✓
- **spec §4.2 跟随抑制** → Task 2（`__lyricsCaretActive` 门控 setCue）+ Task 3 Step6/7（enter 置 true、exit 置 false）。✓
- **spec §4.2 __lyricsScrollToCue** → Task 2 Step4 + Task1 `_lineMove` 调用。✓
- **spec §4.3 CaretSurface.lyrics** → Task 3 Step2。✓
- **spec §4.3 注入** → Task 3 Step5。✓
- **spec §4.3 各 _caret* lyrics 分支** → Task 3 Step4/6/7/8/9/10/11/12/13。✓
- **spec §5 进入/退出/不破坏** → Task 3 Step6/7/14；inactive 路径零改动（仅在 `_lyricsMode`/`_caretOnLyrics` 为真时分流）。✓
- **spec §6 测试三层** → Task1（生成/invocation）、Task2（生成器门控）、Task3 Step15（源码扫描守卫）、Task4 Step6（设备集成，留用户）。✓
- **spec §7 风险①就绪守卫** → Task 3 Step5 注入点 `_readerContentReady` 已置位（已核验）。✓
- **类型一致性**：所有 invocation 方法名（enter/exit/move/scrollPage/lookup/activate/longPress/refresh/suspend/resume/init）在 Task1 定义、Task3 调用一致；`_caretOnLyrics` getter Task3 Step3 定义、后续步骤引用一致。✓
- **占位符扫描**：无 TBD/TODO；每个代码步骤含完整代码。✓
