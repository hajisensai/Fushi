import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart' show enableFocusNavigation;
import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedDictionary,
        seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说阅读器三种 view mode（翻页 / 滚动 / VN）× 两种书写方向的冒烟测试。
///
/// 起因：Linux 桌面端（WPE WebKit）接入后，要把 Windows（WebView2）与 macOS / iOS
/// （WKWebView）上出过的阅读器 bug 在 Linux 上按三种模式各过一遍（CLAUDE.md 规定排版
/// 类问题必须三种模式各验）。检查点按 docs/bugs 里约 500 条阅读器 bug 归成的类别取
/// 「能用一次 JS 读数判死活」的那一层，平台无关——同一份在 Windows / macOS 上照跑：
///
///   1. 冷开书就绪（BUG-019 / 1017 / 1199 白屏；VN 舞台 BUG-2614 / 718）
///   2. 视口几何非零（BUG-1812 vh/vw 为 0、BUG-2639）与书写方向生效
///   3. 注音：每个可见 ruby 的行盒与 rt 盒非零（WebKit BUG-2472 / 2482 行盒塌成零高），
///      竖排注音在基字右侧、横排在上方（BUG-611 / 666 / 695）
///   4. 键盘 PageDown 真前进（BUG-099 / 317 / 368 / 2364）
///   5. 插图加载完成且不超出页框（BUG-351 / 501 / 568 / 1828 / 2468）
///   6. 跨章：短章末尾继续 PageDown 落到下一章章首（BUG-240 / 369 / 2015 / 2424）
///   7. VN：当前屏内容不溢出舞台（BUG-2575 / 2576 / 1688）
///   8. 退出重进恢复位置（BUG-155 / 162 / 587 / 2388 / 2465 / 2556 / 2576；之前没有
///      小说的退出→重进 itest）
///   9. 阅读器内焦点驱动查词：Enter 进正文光标 → Enter 查词 → 真词典弹窗出现并渲染
///      → Esc 关闭（BUG-1419 / 468 / 2632）
///
/// 全部组合跑完再统一断言，一次运行拿到完整矩阵。fixture 是 helpers 里的 8 章生成书
/// 加两章真 PNG 插图（`withRealImages`；用到 chapter_02_short / 04_ruby / 07_long /
/// 10_photo_text）。
///
/// Linux（Docker / Xvfb）：`flutter test integration_test/reader_view_modes_smoke_itest.dart -d linux`
/// Windows：`powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 integration_test/reader_view_modes_smoke_itest.dart`

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

const List<String> _kViewModes = <String>['paginated', 'continuous', 'vn'];
const List<String> _kWritingModes = <String>['vertical-rl', 'horizontal-tb'];

const int _kShortChapter = 1; // chapter_02_short
const int _kImageChapter = 9; // chapter_10_photo_text（真 PNG 插图 + 正文）
const int _kRubyChapter = 3; // chapter_04_ruby
const int _kLongChapter = 6; // chapter_07_long

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  int polls = 120,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (int i = 0; i < polls; i++) {
    if (ready()) return true;
    await tester.pump(step);
  }
  return ready();
}

Future<Map<String, dynamic>> _js(String source) async {
  final Future<dynamic> Function(String source)? run =
      ReaderFushiPage.debugEvaluateJavascript;
  if (run == null) return <String, dynamic>{'error': 'no JS hook'};
  try {
    final Object? raw = await run(source);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final Object? decoded = jsonDecode(raw?.toString() ?? 'null');
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{'value': decoded};
  } catch (e) {
    return <String, dynamic>{'error': '$e'};
  }
}

/// 位置读数：章文件、首个可见字、VN 屏号、滚动坐标。
const String _positionJs = r'''
(function () {
  var r = window.fushiReader;
  var se = document.scrollingElement || document.documentElement;
  return JSON.stringify({
    file: (document.baseURI || '').split('/').pop(),
    firstChar: (r && typeof r.getFirstVisibleCharOffset === 'function')
      ? r.getFirstVisibleCharOffset() : -1,
    vnIdx: (r && typeof r.currentScreenIndex === 'number') ? r.currentScreenIndex : -1,
    progress: (r && typeof r.calculateProgress === 'function') ? r.calculateProgress() : -1,
    sx: se.scrollLeft, sy: se.scrollTop
  });
})()
''';

/// 冷开书 / 视口 / 书写方向 / VN 舞台。
const String _basicJs = r'''
(function () {
  var stage = document.querySelector('.fushi-vn-stage');
  var content = document.querySelector('.fushi-vn-content');
  var wmEl = content || document.body;
  return JSON.stringify({
    textLen: (document.body.innerText || '').trim().length,
    cloak: !!document.getElementById('fushi-cloak'),
    bodyVisibility: getComputedStyle(document.body).visibility,
    innerW: window.innerWidth, innerH: window.innerHeight,
    clientW: document.documentElement.clientWidth,
    clientH: document.documentElement.clientHeight,
    writingMode: getComputedStyle(wmEl).writingMode,
    vnStage: !!stage,
    vnStageText: stage ? (stage.textContent || '').trim().length : 0
  });
})()
''';

/// 注音几何：只看视口内（含 VN 当前屏）的 ruby。
const String _rubyJs = r'''
(function () {
  var vw = window.innerWidth, vh = window.innerHeight;
  var vertical = getComputedStyle(document.querySelector('.fushi-vn-content') || document.body)
    .writingMode.indexOf('vertical') === 0;
  var rubies = Array.prototype.slice.call(document.querySelectorAll('ruby'));
  var checked = 0, zeroLine = 0, zeroRt = 0, misplaced = 0, samples = [];
  rubies.forEach(function (ruby) {
    var rr = ruby.getBoundingClientRect();
    if (rr.right <= 0 || rr.bottom <= 0 || rr.left >= vw || rr.top >= vh) return;
    if (rr.width === 0 && rr.height === 0) return; // 不在当前屏（VN 隐藏屏）
    var rt = ruby.querySelector('rt');
    if (!rt) return;
    checked++;
    var lines = ruby.getClientRects();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].width <= 0 || lines[i].height <= 0) { zeroLine++; break; }
    }
    var rtRect = rt.getBoundingClientRect();
    if (rtRect.width <= 0 || rtRect.height <= 0) { zeroRt++; return; }
    var range = document.createRange();
    var base = null;
    for (var n = ruby.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 && n.textContent.trim()) { base = n; break; }
      if (n.nodeType === 1 && n.tagName !== 'RT' && n.tagName !== 'RP' && n.tagName !== 'RTC') { base = n; break; }
    }
    if (!base) return;
    range.selectNodeContents(base);
    var b = range.getBoundingClientRect();
    if (b.width <= 0 || b.height <= 0) return;
    var cx = (rtRect.left + rtRect.right) / 2, cy = (rtRect.top + rtRect.bottom) / 2;
    var bad = vertical ? (cx < b.right - 1) : (cy > b.top + 1);
    if (bad) {
      misplaced++;
      if (samples.length < 3) samples.push({
        base: (base.textContent || '').slice(0, 6),
        b: [Math.round(b.left), Math.round(b.top), Math.round(b.right), Math.round(b.bottom)],
        rt: [Math.round(rtRect.left), Math.round(rtRect.top), Math.round(rtRect.right), Math.round(rtRect.bottom)]
      });
    }
  });
  return JSON.stringify({ total: rubies.length, checked: checked, zeroLine: zeroLine,
    zeroRt: zeroRt, misplaced: misplaced, vertical: vertical, samples: samples });
})()
''';

/// 插图：加载完成、尺寸非零、不超出视口（滚动模式只看与书写方向垂直的那一维）。
const String _imagesJs = r'''
(function (continuous) {
  var vw = window.innerWidth, vh = window.innerHeight;
  var vertical = getComputedStyle(document.querySelector('.fushi-vn-content') || document.body)
    .writingMode.indexOf('vertical') === 0;
  var imgs = Array.prototype.slice.call(document.querySelectorAll('img, svg'));
  var pending = 0, broken = 0, oversize = 0;
  var visible = 0;
  imgs.forEach(function (img) {
    var vr = img.getBoundingClientRect();
    // 视口外的图按设计懒加载（loading=lazy，BUG-1140），只判视口内的。
    if (vr.right <= 0 || vr.bottom <= 0 || vr.left >= vw || vr.top >= vh) return;
    if (vr.width === 0 && vr.height === 0 && img.complete) return;
    visible++;
    if (img.tagName.toLowerCase() === 'img') {
      if (!img.complete) { pending++; return; }
      if (!img.naturalWidth) { broken++; return; }
    }
    var r = img.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return; // 不在当前屏
    var overW = r.width > vw + 1, overH = r.height > vh + 1;
    if (continuous ? (vertical ? overH : overW) : (overW || overH)) oversize++;
  });
  return JSON.stringify({ count: imgs.length, visible: visible, pending: pending, broken: broken, oversize: oversize });
})(__CONTINUOUS__)
''';

/// VN：当前屏内容不溢出（量尺被压掉 BUG-2575 时 scroll 尺寸会大于 client 尺寸）。
const String _vnFitJs = r'''
(function () {
  var c = document.querySelector('.fushi-vn-screen:not([hidden]) .fushi-vn-content')
    || document.querySelector('.fushi-vn-content');
  if (!c) return JSON.stringify({ present: false });
  return JSON.stringify({ present: true,
    overflowY: c.scrollHeight - c.clientHeight, overflowX: c.scrollWidth - c.clientWidth });
})()
''';

class _ComboResult {
  _ComboResult(this.viewMode, this.writingMode);

  final String viewMode;
  final String writingMode;
  final List<String> failures = <String>[];
  final Map<String, Object?> evidence = <String, Object?>{};

  String get label => '$viewMode/$writingMode';

  void check(bool ok, String what) {
    if (!ok) failures.add('$label: $what');
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<bool> _open(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  final bool webView = await _waitFor(
    tester,
    () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
  );
  final bool ready = await _waitFor(tester, _contentReady, polls: 240);
  final bool hooks = await _waitFor(
    tester,
    () => ReaderFushiPage.debugEvaluateJavascript != null,
    polls: 40,
  );
  await _pumpFor(tester, const Duration(seconds: 2));
  return webView && ready && hooks;
}

Future<void> _close(WidgetTester tester) async {
  if (_readerGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerGone, polls: 80);
  await _pumpFor(tester, const Duration(seconds: 1));
}

/// 跳到第 [section] 章并等到 DOM 真换成那一章。
Future<bool> _jump(WidgetTester tester, int section, String fileHint) async {
  final Future<void> Function(int sectionIndex)? jump =
      ReaderFushiPage.debugJumpSection;
  if (jump == null) return false;
  await jump(section);
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (!_contentReady()) continue;
    final Map<String, dynamic> pos = await _js(_positionJs);
    if ((pos['file'] as String? ?? '').contains(fileHint)) {
      await _pumpFor(tester, const Duration(milliseconds: 1500));
      return true;
    }
  }
  return false;
}

Future<void> _pageDown(WidgetTester tester, int times) async {
  for (int i = 0; i < times; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _pumpFor(tester, const Duration(milliseconds: 600));
  }
}

int _int(Object? v) => (v as num?)?.toInt() ?? -1;

/// 「前进了」：VN 看屏号，其余看首个可见字（滚动模式再看滚动坐标兜底）。
bool _advanced(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
  String viewMode,
) {
  if (viewMode == 'vn') return _int(after['vnIdx']) > _int(before['vnIdx']);
  if (_int(after['firstChar']) > _int(before['firstChar'])) return true;
  return viewMode == 'continuous' &&
      (after['sx'] != before['sx'] || after['sy'] != before['sy']);
}

Future<void> _runCombo(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  _ComboResult r,
) async {
  await source.setReaderWritingMode(r.writingMode);
  await source.setReaderViewMode(r.viewMode);
  await _pumpFor(tester, const Duration(milliseconds: 800));

  // 1 + 2. 冷开书 / 视口 / 书写方向。
  final bool ready = await _open(tester, bookKey);
  r.check(ready, 'content never ready on cold open');
  if (!ready) return;
  final Map<String, dynamic> basic = await _js(_basicJs);
  r.evidence['basic'] = basic;
  r.check(_int(basic['textLen']) > 0, 'blank page (no text)');
  r.check(basic['cloak'] != true, 'cloak still covering content');
  r.check(basic['bodyVisibility'] != 'hidden', 'body still hidden');
  r.check(
    _int(basic['innerW']) > 0 && _int(basic['innerH']) > 0,
    'zero viewport ${basic['innerW']}x${basic['innerH']}',
  );
  r.check(
    (basic['writingMode'] as String? ?? '').startsWith(
      r.writingMode == 'vertical-rl' ? 'vertical' : 'horizontal',
    ),
    'writing-mode not applied (${basic['writingMode']})',
  );
  if (r.viewMode == 'vn') {
    r.check(basic['vnStage'] == true, 'no VN stage');
    r.check(_int(basic['vnStageText']) > 0, 'VN stage empty');
  }

  // 3. 注音。
  final bool onRuby = await _jump(tester, _kRubyChapter, 'chapter_04_ruby');
  r.check(onRuby, 'jump to ruby chapter did not land');
  if (onRuby) {
    Map<String, dynamic> ruby = await _js(_rubyJs);
    // VN 把源节点按屏克隆，章首屏可能只有标题：往后翻到第一块带注音的屏。
    for (
      int i = 0;
      i < 8 && _int(ruby['checked']) == 0 && r.viewMode == 'vn';
      i++
    ) {
      await _pageDown(tester, 1);
      ruby = await _js(_rubyJs);
    }
    r.evidence['ruby'] = ruby;
    r.check(_int(ruby['checked']) > 0, 'no visible ruby to check');
    r.check(_int(ruby['zeroLine']) == 0, 'ruby line box collapsed: $ruby');
    r.check(_int(ruby['zeroRt']) == 0, 'rt box collapsed: $ruby');
    r.check(_int(ruby['misplaced']) == 0, 'ruby annotation misplaced: $ruby');

    // 4. 键盘翻页（注音章体量足够翻两页）。
    final Map<String, dynamic> before = await _js(_positionJs);
    await _pageDown(tester, 2);
    final Map<String, dynamic> after = await _js(_positionJs);
    r.evidence['pageDown'] = <String, Object?>{
      'before': before,
      'after': after,
    };
    r.check(
      _advanced(before, after, r.viewMode),
      'PageDown did not advance ($before -> $after)',
    );
  }

  // 5. 插图。
  final bool onImages = await _jump(
    tester,
    _kImageChapter,
    'chapter_10_photo_text',
  );
  r.check(onImages, 'jump to image chapter did not land');
  if (onImages) {
    Map<String, dynamic> imgs = <String, dynamic>{};
    for (int i = 0; i < 20; i++) {
      imgs = await _js(
        _imagesJs.replaceFirst(
          '__CONTINUOUS__',
          r.viewMode == 'continuous' ? 'true' : 'false',
        ),
      );
      if (_int(imgs['pending']) == 0) break;
      await _pumpFor(tester, const Duration(milliseconds: 500));
    }
    r.evidence['images'] = imgs;
    r.check(
      _int(imgs['visible']) > 0,
      'no image visible on the image chapter: $imgs',
    );
    r.check(_int(imgs['pending']) == 0, 'images never finished loading');
    r.check(_int(imgs['broken']) == 0, 'broken images: $imgs');
    r.check(_int(imgs['oversize']) == 0, 'image exceeds page box: $imgs');
  }

  // 6. 跨章：短章翻到底继续 PageDown，必须落到下一章章首。
  final bool onShort = await _jump(tester, _kShortChapter, 'chapter_02_short');
  r.check(onShort, 'jump to short chapter did not land');
  if (onShort) {
    Map<String, dynamic> pos = await _js(_positionJs);
    bool crossed = false;
    for (int i = 0; i < 40 && !crossed; i++) {
      await _pageDown(tester, 1);
      pos = await _js(_positionJs);
      crossed = !(pos['file'] as String? ?? '').contains('chapter_02_short');
    }
    if (crossed) {
      // 等新章 settle（重锚 / 进度刷新）再读落点。
      await _pumpFor(tester, const Duration(seconds: 2));
      pos = await _js(_positionJs);
    }
    r.evidence['crossChapter'] = pos;
    r.check(crossed, 'PageDown never crossed into the next chapter');
    r.check(
      !crossed || (pos['file'] as String? ?? '').contains('chapter_03'),
      'crossed into the wrong chapter (${pos['file']})',
    );
    final double progress = (pos['progress'] as num?)?.toDouble() ?? -1;
    r.check(
      !crossed || progress < 0.2,
      'forward chapter turn did not land at chapter start (progress=$progress)',
    );
  }

  // 7. VN 屏溢出。
  if (r.viewMode == 'vn') {
    final Map<String, dynamic> fit = await _js(_vnFitJs);
    r.evidence['vnFit'] = fit;
    r.check(fit['present'] == true, 'VN content element missing');
    r.check(
      _int(fit['overflowY']) <= 2 && _int(fit['overflowX']) <= 2,
      'VN screen overflows its stage: $fit',
    );
  }

  // 8. 退出重进恢复位置（长章中段）。
  final bool onLong = await _jump(tester, _kLongChapter, 'chapter_07_long');
  r.check(onLong, 'jump to long chapter did not land');
  if (onLong) {
    final Map<String, dynamic> start = await _js(_positionJs);
    await _pageDown(tester, 4);
    final Map<String, dynamic> saved = await _js(_positionJs);
    // 位置落库有 500ms 去抖；退出路径也会 flush，这里留足余量。
    await _pumpFor(tester, const Duration(seconds: 3));
    await _close(tester);
    final bool reopened = await _open(tester, bookKey);
    r.check(reopened, 'content never ready on reopen');
    if (reopened) {
      final Map<String, dynamic> restored = await _js(_positionJs);
      r.evidence['restore'] = <String, Object?>{
        'start': start,
        'saved': saved,
        'restored': restored,
      };
      r.check(
        restored['file'] == saved['file'],
        'reopen landed in ${restored['file']} instead of ${saved['file']}',
      );
      if (r.viewMode == 'vn') {
        r.check(
          _int(saved['vnIdx']) <= 0 || _int(restored['vnIdx']) > 0,
          'VN reopen fell back to screen 0 (saved ${saved['vnIdx']})',
        );
      } else {
        final int savedChar = _int(saved['firstChar']);
        final int perPage = ((savedChar - _int(start['firstChar'])) / 4)
            .round()
            .abs();
        final int drift = (_int(restored['firstChar']) - savedChar).abs();
        r.check(
          savedChar <= 0 || _int(restored['firstChar']) > 0,
          'reopen fell back to chapter start (saved char $savedChar)',
        );
        r.check(
          drift <= perPage * 1.5 + 20,
          'reopen drifted $drift chars (one page ≈ $perPage)',
        );
      }
    }
  }

  // 9. 焦点驱动查词：Enter 进正文光标 → Enter 查当前字 → 真弹窗渲染 → Esc 关。
  if (!_readerGone()) {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final bool caret = await _waitFor(
      tester,
      () => ReaderFushiPage.debugCaretSurface?.call() == 'reader',
      polls: 40,
    );
    if (!caret) {
      final Map<String, dynamic> direct = await _js(
        'JSON.stringify(window.fushiCaret ? window.fushiCaret.enter() : {missing: true})',
      );
      r.evidence['caretDiag'] = <String, Object?>{
        'surface': ReaderFushiPage.debugCaretSurface?.call(),
        'primaryFocus': FocusManager.instance.primaryFocus?.toString(),
        'directEnter': direct,
      };
    }
    r.check(caret, 'Enter did not enter the text caret');
    if (caret) {
      // 判「真查到了」不能看 DictionaryPopupWebView 在不在树里：阅读器开书时会预热
      // 一个离屏热槽弹窗，它恒在、Esc 也不会移除它。与 reader_vn_lookup_jump_itest
      // 同一判据：光标所在面切到 popup（真词典结果渲染后才交出光标）。
      // 光标从首个可见字起步，翻页 / VN 下那常是「【」之类的标点——标点查不到词、
      // 本就不弹窗。先按 Tab 走到假名 / 汉字上再查。
      Map<String, dynamic> caretAt = <String, dynamic>{};
      for (int i = 0; i < 20; i++) {
        caretAt = await _js(
          'JSON.stringify((function () { var c = window.fushiCaret; '
          'return { active: !!(c && c.isActive && c.isActive()), '
          "ch: c && c.node ? c.node.textContent.substr(c.offset, 1) : '' }; })())",
        );
        if (RegExp(r'[ぁ-ヿ一-鿿]')
            .hasMatch(caretAt['ch'] as String? ?? '')) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFor(tester, const Duration(milliseconds: 150));
      }
      final Map<String, dynamic> caretProbe = await _js(
        'JSON.stringify((function () { var c = window.fushiCaret; '
        'return { active: !!(c && c.isActive && c.isActive()), '
        "ch: c && c.node ? c.node.textContent.substr(c.offset, 1) : '' }; })())",
      );
      r.evidence['caretAt'] = caretAt;
      r.evidence['caretProbe'] = caretProbe;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      final bool popup = await _waitFor(
        tester,
        () => ReaderFushiPage.debugCaretSurface?.call() == 'popup',
        polls: 80,
      );
      r.evidence['surfaceAfterLookup'] =
          ReaderFushiPage.debugCaretSurface?.call();
      r.check(popup, 'caret lookup never handed the caret to a dictionary popup');
      if (popup) {
        String popupText = '';
        for (int i = 0; i < 40 && popupText.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          final Object? raw = await ReaderFushiPage.debugEvaluateTopPopup?.call(
            "(document.body && document.body.innerText || '').trim()",
          );
          popupText = raw?.toString() ?? '';
          if (popupText == 'null') popupText = '';
        }
        r.evidence['popupTextLen'] = popupText.length;
        r.check(popupText.isNotEmpty, 'dictionary popup rendered nothing');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        final bool closed = await _waitFor(
          tester,
          () => ReaderFushiPage.debugCaretSurface?.call() != 'popup',
          polls: 40,
        );
        r.evidence['surfaceAfterEsc'] = ReaderFushiPage.debugCaretSurface?.call();
        r.check(closed, 'Esc did not close the dictionary popup');
      }
      // 退出正文光标，别把焦点状态带进下一组合。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFor(tester, const Duration(milliseconds: 500));
    }
  }

  try {
    final ObserveShot shot = await captureReaderWebView(
      'view-modes-${r.viewMode}-${r.writingMode}',
    );
    r.evidence['screenshot'] = shot.path;
  } catch (e) {
    r.evidence['screenshot'] = 'capture failed: $e';
  }
  await _close(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reader smoke: paginated / continuous / vn × vertical / horizontal',
    timeout: const Timeout(Duration(minutes: 45)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'view-modes',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await _pumpFor(tester, const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          // 第 9 项「Enter 进正文光标查词」属于焦点导航（实验开关），与
          // reader_vn_lookup_jump_itest 一样先打开、finally 里还原。
          final bool baseFocusNavigation =
              appModel.experimentalFocusNavigationEnabled;
          await enableFocusNavigation(tester);
          expect(await seedDictionary(tester), isTrue);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String baseViewMode = source.readerViewMode;
          final String baseWritingMode = source.readerWritingMode;
          final List<_ComboResult> results = <_ComboResult>[];
          try {
            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'view_modes_smoke.epub',
              withRealImages: true,
            );
            for (final String writingMode in _kWritingModes) {
              for (final String viewMode in _kViewModes) {
                final _ComboResult r = _ComboResult(viewMode, writingMode);
                results.add(r);
                try {
                  await _runCombo(tester, source, bookKey, r);
                } catch (e, st) {
                  r.failures.add('${r.label}: threw $e\n$st');
                  await _close(tester);
                }
                debugPrint(
                  '[view-modes] ${r.label} '
                  '${r.failures.isEmpty ? 'PASS' : 'FAIL'} '
                  'evidence=${jsonEncode(r.evidence)}',
                );
                for (final String f in r.failures) {
                  debugPrint('[view-modes]   ✗ $f');
                }
              }
            }
          } finally {
            await _close(tester);
            await source.setReaderViewMode(baseViewMode);
            await source.setReaderWritingMode(baseWritingMode);
            await appModel.setExperimentalFocusNavigationEnabled(
              baseFocusNavigation,
            );
          }
          final List<String> all = <String>[
            for (final _ComboResult r in results) ...r.failures,
          ];
          debugPrint(
            '[view-modes] summary: '
            '${results.where((_ComboResult r) => r.failures.isEmpty).length}'
            '/${results.length} combos passed',
          );
          expect(all, isEmpty, reason: all.join('\n'));
        },
      );
    },
  );
}
