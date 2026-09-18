import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2575 / BUG-2576 真机证据（真 WebView + 真引擎 + 真安全区；iOS 模拟器优先）。
///
/// BUG-2575：VN 切屏的量尺 `createScreenMeasurement` 与真实屏共用 `.fushi-vn-screen`，
/// 样式表里 `width/height: 100% !important` 压过普通内联尺寸，量尺一直是整视口而真屏
/// 是视口减 chrome 预留带——竖排多出一列贴左被裁、横排末行进底栏。这里在 live
/// WebView 上锁三条不变式（竖排、横排各一遍）：
///   1. 量尺根盒的高宽 == 当前 `.fushi-vn-screen` 盒（±1px）；
///   2. 逐屏渲染，每屏所有文本行盒都落在 `.fushi-vn-screen` 盒内（±4px，见探针注释）；
///   3. 每屏文本与整章源文连续一致（切屏没有错序 / 丢字）。
/// BUG-2576：`restoreProgress(0.99)`（往前翻章的「章末」约定值）必须落到末屏。
///
/// Run（iOS 模拟器，from repo root）：
///   .\tool\run_mac_itest.ps1 integration_test/reader_vn_screen_fit_itest.dart -Ios
/// Run（Windows 离屏）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_vn_screen_fit_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) {
      debugPrint('[vn-fit] $label ready after ${i * step.inMilliseconds}ms');
      return true;
    }
  }
  debugPrint(
    '[vn-fit] $label NOT ready within ${maxPolls * step.inMilliseconds}ms',
  );
  return false;
}

/// 量尺 vs 真屏 + 逐屏溢出扫描 + 文本连续性。逐屏 renderScreen 后落回原屏。
const String _fitProbeJs = r'''
(function () {
  var r = window.fushiReader;
  if (!r || !r.screens || !r.screen) return JSON.stringify({ hasReader: false });
  var strip = function (s) { return String(s || '').replace(/\s+/g, ''); };
  var textOf = function (root) {
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        return (n.parentElement && n.parentElement.closest('rt,rp'))
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    var s = ''; var n;
    while ((n = w.nextNode())) s += n.textContent;
    return strip(s);
  };
  var sb = r.screen.getBoundingClientRect();
  var out = {
    hasReader: true,
    writingMode: getComputedStyle(document.body).writingMode,
    innerWidth: window.innerWidth, innerHeight: window.innerHeight,
    screenBox: [sb.left, sb.top, sb.width, sb.height],
    screens: r.screens.length, idx: r.currentScreenIndex
  };
  var m = r.createScreenMeasurement();
  if (m && m.root) {
    var mb = m.root.getBoundingClientRect();
    out.mirrorBox = [mb.left, mb.top, mb.width, mb.height];
    out.mirrorClient = [m.root.clientWidth, m.root.clientHeight];
    out.mirrorPriority = [m.root.style.getPropertyPriority('width'),
      m.root.style.getPropertyPriority('height')];
    m.root.parentNode.removeChild(m.root);
  }
  var source = textOf(r.sourceRoot);
  var original = r.currentScreenIndex;
  var joined = '';
  var perScreen = [];
  var range = document.createRange();
  for (var i = 0; i < r.screens.length; i++) {
    r.renderScreen(i, true);
    var box = r.screen.getBoundingClientRect();
    var t = textOf(r.screen);
    joined += t;
    var outside = 0, total = 0;
    var over = { l: 0, r: 0, t: 0, b: 0 };
    var w2 = document.createTreeWalker(r.screen, NodeFilter.SHOW_TEXT);
    var n2;
    while ((n2 = w2.nextNode())) {
      if (!String(n2.textContent || '').trim()) continue;
      range.selectNodeContents(n2);
      var rects = range.getClientRects();
      for (var k = 0; k < rects.length; k++) {
        var rc = rects[k];
        if (!rc.width && !rc.height) continue;
        total++;
        over.l = Math.max(over.l, box.left - rc.left);
        over.r = Math.max(over.r, rc.right - box.right);
        over.t = Math.max(over.t, box.top - rc.top);
        over.b = Math.max(over.b, rc.bottom - box.bottom);
        // 容差 4px：iOS WebKit 横排行末全角标点的行盒比屏盒宽出 ~2px（字形本体
        // 占左半 em，右侧是空白，不是可见裁切）；BUG-2575 的真溢出是整列 / 整行
        // 级（≥ 一个字号），4px 不会放过它。
        if (rc.left < box.left - 4 || rc.right > box.right + 4 ||
            rc.top < box.top - 4 || rc.bottom > box.bottom + 4) outside++;
      }
    }
    var cb = document.querySelector('.fushi-vn-content');
    var cbr = cb ? cb.getBoundingClientRect() : null;
    perScreen.push({
      i: i, len: t.length, outside: outside, total: total,
      over: [over.l, over.r, over.t, over.b].map(function (v) { return Math.round(v * 100) / 100; }),
      content: cbr ? [Math.round(cbr.top), Math.round(cbr.bottom), Math.round(cbr.height)] : null,
      contiguous: t.length === 0 || source.indexOf(t) >= 0
    });
  }
  r.renderScreen(original, true);
  out.sourceLen = source.length;
  out.joinedEqualsSource = joined === source;
  out.perScreen = perScreen;
  return JSON.stringify(out);
})()
''';

/// 当前屏的盒几何：屏 / 内容盒 / 首个块级子元素 / 首末文本行盒 + 关键 computed
/// style（谁在裁切）。
const String _geomProbeJs = r'''
(function () {
  var r = window.fushiReader;
  var rect = function (el) { if (!el) return null; var b = el.getBoundingClientRect(); return [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; };
  var cs = function (el) { if (!el) return null; var c = getComputedStyle(el); return { display: c.display, overflow: c.overflow, overflowX: c.overflowX, overflowY: c.overflowY, height: c.height, maxHeight: c.maxHeight, width: c.width, maxWidth: c.maxWidth, columnWidth: c.columnWidth, columnCount: c.columnCount, writingMode: c.writingMode, clipPath: c.clipPath, contain: c.contain, position: c.position, flex: c.flex, alignSelf: c.alignSelf }; };
  var content = document.querySelector('.fushi-vn-content');
  var block = content ? content.firstElementChild : null;
  var rects = [];
  var range = document.createRange();
  var w = document.createTreeWalker(r.screen, NodeFilter.SHOW_TEXT); var n;
  while ((n = w.nextNode())) { if (!String(n.textContent || '').trim()) continue; range.selectNodeContents(n); var rs = range.getClientRects(); for (var k = 0; k < rs.length; k++) rects.push([Math.round(rs[k].left), Math.round(rs[k].top), Math.round(rs[k].width), Math.round(rs[k].height)]); }
  return JSON.stringify({ hidden: document.hidden, idx: r.currentScreenIndex,
    stage: rect(r.stage), screen: rect(r.screen), content: rect(content), block: rect(block),
    blockTag: block ? block.tagName : null, rects: rects.slice(0, 12), rectCount: rects.length,
    csScreen: cs(r.screen), csContent: cs(content), csBlock: cs(block), csBody: cs(document.body) });
})()
''';

const String _idxProbeJs = r'''
(function () {
  var r = window.fushiReader;
  return JSON.stringify({ idx: r ? r.currentScreenIndex : -1,
    screens: r && r.screens ? r.screens.length : -1 });
})()
''';

typedef _RunJs = Future<dynamic> Function(String source);

Future<Map<String, dynamic>> _eval(_RunJs runJs, String js) async {
  final Object? raw = await runJs(js);
  return raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
}

Future<bool> _openAndWait(
  WidgetTester tester,
  String bookKey,
  String label,
) async {
  await openBookViaProductionPath(tester, bookKey);
  final bool webView = await _waitFor(tester, _webViewShown, '$label WebView');
  final bool content = await _waitFor(
    tester,
    _contentReady,
    '$label content',
    maxPolls: 60,
  );
  final bool hooks = await _waitFor(
    tester,
    readerWebViewReady,
    '$label debug hooks',
    maxPolls: 20,
  );
  // 首载后 Dart 会补推一次 chrome insets（整章 refit），等它落定再量。
  await tester.pump(const Duration(seconds: 3));
  debugPrint('[vn-fit] $label webView=$webView content=$content hooks=$hooks');
  return webView && content;
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 一种书写方向的完整校验；把失败追加进 [failures]。
Future<void> _verifyWritingMode(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  String writingMode,
  List<String> failures,
) async {
  final String tag = writingMode == 'vertical-rl' ? 'V' : 'H';
  await source.setReaderWritingMode(writingMode);
  await _pumpForPref(tester);
  final bool ready = await _openAndWait(tester, bookKey, '$tag open');
  if (!ready) {
    failures.add('$tag: content never ready');
    await _closeReader(tester);
    return;
  }
  final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
  if (runJs == null) {
    failures.add('$tag: no JS hook');
    await _closeReader(tester);
    return;
  }
  final ObserveShot before = await captureReaderWebView('vn-fit-$tag-before');
  debugPrint('[vn-fit] $tag webview before saved=${before.saved} '
      'nonBlank=${before.nonBlank} path=${before.path}');

  final Map<String, dynamic> fit = await _eval(runJs, _fitProbeJs);
  final Map<String, dynamic> summary = Map<String, dynamic>.from(fit)
    ..remove('perScreen');
  debugPrint('[vn-fit] $tag fit ${jsonEncode(summary)}');
  if (fit['hasReader'] != true) {
    failures.add('$tag: VN reader missing');
    await _closeReader(tester);
    return;
  }
  final String wm = fit['writingMode']?.toString() ?? '';
  if (!wm
      .startsWith(writingMode == 'vertical-rl' ? 'vertical' : 'horizontal')) {
    failures.add('$tag: writing mode not applied (got $wm)');
  }
  final List<num> screenBox = (fit['screenBox'] as List).cast<num>();
  final List<num>? mirrorBox = (fit['mirrorBox'] as List?)?.cast<num>();
  final List<dynamic>? priority = fit['mirrorPriority'] as List?;
  if (mirrorBox == null) {
    failures.add('$tag: createScreenMeasurement returned no root');
  } else {
    // BUG-2575 不变式 1：量尺盒 == 真屏盒。修前这里 mirror 高 == innerHeight。
    if ((mirrorBox[2] - screenBox[2]).abs() > 1 ||
        (mirrorBox[3] - screenBox[3]).abs() > 1) {
      failures.add('$tag: measurement mirror ${mirrorBox.join(",")} != '
          'screen box ${screenBox.join(",")} (innerHeight=${fit['innerHeight']})');
    }
    if (priority == null ||
        priority[0] != 'important' ||
        priority[1] != 'important') {
      failures.add('$tag: mirror size priority $priority (want important)');
    }
  }
  final List<dynamic> perScreen = fit['perScreen'] as List;
  final int screens = (fit['screens'] as num).toInt();
  if (screens < 3) failures.add('$tag: only $screens screens built');
  int overflowScreens = 0;
  int outsideRects = 0;
  int nonContiguous = 0;
  for (final dynamic raw in perScreen) {
    final Map<String, dynamic> s = Map<String, dynamic>.from(raw as Map);
    final int outside = (s['outside'] as num).toInt();
    if (outside > 0) {
      overflowScreens++;
      outsideRects += outside;
      if (overflowScreens <= 5) {
        debugPrint('[vn-fit] $tag overflow screen ${s['i']} '
            'outside=$outside/${s['total']} len=${s['len']} '
            'over(l,r,t,b)=${s['over']} content(top,bottom,h)=${s['content']}');
      }
    }
    if (s['contiguous'] != true) nonContiguous++;
  }
  debugPrint('[vn-fit] $tag screens=$screens overflowScreens=$overflowScreens '
      'outsideRects=$outsideRects nonContiguous=$nonContiguous '
      'joinedEqualsSource=${fit['joinedEqualsSource']}');
  // BUG-2575 不变式 2：任何屏都不许有文本行盒溢出真屏盒。
  if (overflowScreens > 0) {
    failures.add('$tag: $overflowScreens/$screens screens overflow the VN '
        'screen box ($outsideRects line boxes outside)');
  }
  // 不变式 3：切屏不丢字不错序。
  if (nonContiguous > 0 || fit['joinedEqualsSource'] != true) {
    failures.add('$tag: screen text not contiguous with the chapter source '
        '(nonContiguous=$nonContiguous joinedEqualsSource='
        '${fit['joinedEqualsSource']})');
  }

  // BUG-2576：restoreProgress(0.99) 必须落末屏。
  await runJs('window.fushiReader.restoreProgress(0.99);');
  await tester.pump(const Duration(seconds: 1));
  final Map<String, dynamic> after = await _eval(runJs, _idxProbeJs);
  debugPrint('[vn-fit] $tag after restoreProgress(0.99) ${jsonEncode(after)}');
  final int idx = (after['idx'] as num).toInt();
  final int n = (after['screens'] as num).toInt();
  if (n <= 0 || idx != n - 1) {
    failures.add('$tag: restoreProgress(0.99) landed on screen $idx of $n '
        '(want last = ${n - 1})');
  }
  final Map<String, dynamic> geom = await _eval(runJs, _geomProbeJs);
  debugPrint('[vn-fit] $tag chapter-end geometry ${jsonEncode(geom)}');
  final ObserveShot end = await captureReaderWebView('vn-fit-$tag-chapter-end');
  debugPrint('[vn-fit] $tag webview chapter-end saved=${end.saved} '
      'nonBlank=${end.nonBlank} path=${end.path}');
  // 回到章首再合上，别把 0.99 留给下一次开书的存档。
  await runJs('window.fushiReader.restoreProgress(0);');
  await tester.pump(const Duration(seconds: 1));
  await _closeReader(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'VN screen fit: measurement mirror == real screen box, no screen overflows, '
    'restoreProgress(0.99) lands on the last screen (vertical + horizontal)',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'vn-fit',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home (nav bar) must render',
          );
          await tester.pump(const Duration(seconds: 2));
          await readyAppModel(tester);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String baseViewMode = source.readerViewMode;
          final String baseWritingMode = source.readerWritingMode;
          final List<String> failures = <String>[];
          // macOS 的 MediaQuery.viewPadding 恒为 0，只有挤压（非悬浮）chrome 才产生
          // 预留带；iOS 本身有刘海 / home indicator，两种模式下量尺与真屏都会分离。
          final bool baseTopFloating = source.topProgressFloating;
          final bool baseTapHide = source.tapEmptyToHideChrome;
          try {
            if (source.topProgressFloating) {
              source.toggleTopProgressFloating();
            }
            if (source.tapEmptyToHideChrome) {
              source.toggleTapEmptyToHideChrome();
            }
            await source.setReaderViewMode('vn');
            await _pumpForPref(tester);
            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'vn_fit_probe.epub',
            );
            await _verifyWritingMode(
              tester,
              source,
              bookKey,
              'vertical-rl',
              failures,
            );
            await _verifyWritingMode(
              tester,
              source,
              bookKey,
              'horizontal-tb',
              failures,
            );
            debugPrint('[vn-fit] failures=${jsonEncode(failures)}');
            expect(failures, isEmpty, reason: failures.join('; '));
          } finally {
            await _closeReader(tester);
            await source.setReaderViewMode(baseViewMode);
            await source.setReaderWritingMode(baseWritingMode);
            if (source.topProgressFloating != baseTopFloating) {
              source.toggleTopProgressFloating();
            }
            if (source.tapEmptyToHideChrome != baseTapHide) {
              source.toggleTapEmptyToHideChrome();
            }
          }
        },
      );
    },
  );
}
