import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/page_curl/page_curl.dart';
import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说阅读器「卷页」翻页的真 app 回归（真 WebView + 真分页 shell + 真截图 + 真
/// 着色器叠层）。竖排（vertical-rl，右开、镜像）与横排（horizontal-tb）各一遍：
///
///   1. 按键前进 / 后退：中途 `PageCurlOverlay` 可见且角点在动；结束后叠层撤掉、
///      JS 侧 `_curl` 会话清空、恰好走一页（pagePos ±1）。
///   2. 连按：动画没播完再按 5 次 → 恰好前进 5 页（不丢、不多），再连按 5 次后退回到原页。
///   3. 跟手（CDP 真触摸序列 → JS 手势 → `onPageCurlDrag` → 控制器）：长拖中途角点跟着
///      手指走（记录位移误差），松手翻页；短慢拖松手回卷、页不变；反向长拖翻回上一页。
///   4. 跨章：短章里一路按键前进直到换章（每步都不卡叠层），再后退一页回到上一章末页；
///      章首反向拖动翻回上一章。
///
/// Windows：`powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 integration_test/page_curl_real_app_test.dart`

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

const int _kShortChapter = 0; // chapter_01_standard
const int _kLongChapter = 6; // chapter_07_long

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

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

Future<Object?> _cdp(String method, Map<String, dynamic> params) async {
  final Future<dynamic> Function(String, Map<String, dynamic>)? call =
      ReaderFushiPage.debugCallDevToolsProtocol;
  if (call == null) throw StateError('no CDP hook');
  return call(method, params);
}

const String _positionJs = r'''
(function () {
  var r = window.fushiReader;
  return JSON.stringify({
    file: (document.baseURI || '').split('/').pop(),
    firstChar: (r && typeof r.getFirstVisibleCharOffset === 'function')
      ? r.getFirstVisibleCharOffset() : -1,
    pagePos: (r && typeof r.getPagePosition === 'function' && typeof r.getScrollContext === 'function')
      ? r.getPagePosition(r.getScrollContext()) : null,
    busy: !!(r && typeof r.pageTurnBusy === 'function' && r.pageTurnBusy()),
    curl: !!(r && r._curl),
    pt: document.documentElement.getAttribute('data-fushi-pt'),
    bodyTransform: document.body.style.transform || '',
    errors: window.__ptErrors || null
  });
})()
''';

const String _configJs = r'''
(function () {
  var C = window.__fushiReaderConfig || {};
  return JSON.stringify({
    effectCfg: C.pageTurnAnimation, followCfg: C.pageTurnFollowDrag,
    swipeLeftIsForward: C.swipeLeftIsForward,
    writingMode: getComputedStyle(document.body).writingMode,
    w: window.innerWidth, h: window.innerHeight
  });
})()
''';

const String _installProbesJs = r'''
(function () {
  if (!window.__ptErrors) {
    window.__ptErrors = [];
    window.addEventListener('error', function (e) {
      window.__ptErrors.push(String(e.message || e.error || e));
    });
    window.addEventListener('unhandledrejection', function (e) {
      window.__ptErrors.push('rejection: ' + String(e.reason));
    });
  }
  return JSON.stringify({ ok: true });
})()
''';

/// 卷页叠层里的控制器（没有叠层 = 卷页没启用）。
PageCurlController? _curl() {
  final Finder f = find.byType(PageCurlOverlay);
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().first.widget as PageCurlOverlay).controller;
}

class _Report {
  final List<String> failures = <String>[];
  final Map<String, Object?> evidence = <String, Object?>{};

  void check(bool ok, String what) {
    if (!ok) failures.add(what);
    debugPrint('[page-curl] ${ok ? 'ok  ' : 'FAIL'} $what');
  }
}

int _int(Object? v) => (v as num?)?.toInt() ?? -1;

/// 页距（像素，带符号）：第一次按键前进测得，之后所有「翻了几页」都按它换算。
double _stride = 0;

/// [a] → [b] 走了几页（四舍五入；页距未知时为 null）。
int? _pages(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (_stride == 0) return null;
  final num? pa = a['pagePos'] as num?;
  final num? pb = b['pagePos'] as num?;
  if (pa == null || pb == null) return null;
  return ((pb - pa) / _stride).round();
}

/// 「静止」：控制器空闲、叠层隐藏、JS 侧没有残留会话 / 翻页标记 / 跟手位移。
Future<Map<String, dynamic>> _settled(WidgetTester tester) async {
  for (int i = 0; i < 150; i++) {
    final PageCurlController? c = _curl();
    if (c == null || !c.active) break;
    await tester.pump(const Duration(milliseconds: 20));
  }
  await _pumpFor(tester, const Duration(milliseconds: 400));
  final Map<String, dynamic> pos = await _js(_positionJs);
  final PageCurlController? c = _curl();
  pos['ctlActive'] = c?.active;
  pos['ctlVisible'] = c?.visible;
  return pos;
}

bool _clean(Map<String, dynamic> p) =>
    p['ctlActive'] != true &&
    p['ctlVisible'] != true &&
    p['curl'] == false &&
    p['pt'] == null &&
    p['bodyTransform'] == '' &&
    p['busy'] == false;

Future<bool> _open(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  final bool webView = await _waitFor(
    tester,
    () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
  );
  final bool ready = await _waitFor(tester, _contentReady, polls: 240);
  final bool hooks = await _waitFor(
    tester,
    () =>
        ReaderFushiPage.debugEvaluateJavascript != null &&
        ReaderFushiPage.debugCallDevToolsProtocol != null,
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

Future<bool> _waitFile(WidgetTester tester, String fileHint) async {
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (!_contentReady()) continue;
    final Map<String, dynamic> pos = await _js(_positionJs);
    if ((pos['file'] as String? ?? '').contains(fileHint)) {
      await _pumpFor(tester, const Duration(milliseconds: 1500));
      await _js(_installProbesJs);
      return true;
    }
  }
  return false;
}

Future<bool> _jump(WidgetTester tester, int section, String fileHint) async {
  final Future<void> Function(int sectionIndex)? jump =
      ReaderFushiPage.debugJumpSection;
  if (jump == null) return false;
  await jump(section);
  return _waitFile(tester, fileHint);
}

/// 一次按键翻页：期间逐帧采样控制器（叠层是否出现、角点是否移动）。
Future<Map<String, dynamic>> _keyTurn(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  String? midShot,
}) async {
  await tester.sendKeyEvent(key);
  bool sawVisible = false;
  final Set<int> xs = <int>{};
  String? shot;
  final DateTime end = DateTime.now().add(const Duration(milliseconds: 1500));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    final PageCurlController? c = _curl();
    if (c != null && c.visible) {
      sawVisible = true;
      xs.add(c.geometry.point.dx.round());
      if (midShot != null && shot == null && xs.length >= 4) {
        final ObserveShot f = await captureFlutterFrame(tester, midShot);
        final ObserveShot w = await captureReaderWebView('$midShot-webview');
        shot = '${f.path} | ${w.path}';
      }
    }
    if (sawVisible && c != null && !c.active) break;
  }
  return <String, dynamic>{
    'sawVisible': sawVisible,
    'distinctX': xs.length,
    'shot': shot,
  };
}

/// 未镜像空间里角点应在的位置：前进 = 角点贴着手指（页宽 − 已拖距离）；
/// 后退 = 纸面从书脊外拉回，折边贴着手指，角点按两倍速（−页宽 + 2×已拖距离）。
double _expectedPointX(double width, double dragged, bool backward) =>
    backward ? -width + 2 * dragged : width - dragged;

Future<void> _touch(String type, double x, double y) async {
  await _cdp('Input.dispatchTouchEvent', <String, dynamic>{
    'type': type,
    'touchPoints': type == 'touchEnd'
        ? <Object>[]
        : <Object>[
            <String, Object>{'x': x, 'y': y},
          ],
  });
}

/// 一次拖动：从 ([x0], [y]) 按 [steps] 步移动 [dx]。每步后记录控制器角点与手指的
/// 跟手误差（未镜像空间里角点应 = 页宽 − 已拖距离）。
Future<Map<String, dynamic>> _drag(
  WidgetTester tester, {
  required double x0,
  required double y,
  required double dx,
  required double width,
  required bool mirror,
  bool backward = false,
  required int steps,
  required int stepMs,
  required int holdMs,
  String? midShot,
}) async {
  await _touch('touchStart', x0, y);
  await _pumpFor(tester, Duration(milliseconds: stepMs));
  final List<double> lag = <double>[];
  bool sawVisible = false;
  for (int i = 1; i <= steps; i++) {
    final double x = x0 + dx * i / steps;
    await _touch('touchMove', x, y);
    await _pumpFor(tester, Duration(milliseconds: stepMs));
    final PageCurlController? c = _curl();
    if (c != null && c.visible) {
      sawVisible = true;
      lag.add(
        (c.geometry.point.dx - _expectedPointX(width, (x - x0).abs(), backward))
            .abs(),
      );
    }
  }
  await _pumpFor(tester, Duration(milliseconds: holdMs));
  final PageCurlController? c = _curl();
  final double? heldLag = c != null && c.visible
      ? (c.geometry.point.dx - _expectedPointX(width, dx.abs(), backward)).abs()
      : null;
  String? shot;
  if (midShot != null && c != null && c.visible) {
    final ObserveShot f = await captureFlutterFrame(tester, midShot);
    final ObserveShot w = await captureReaderWebView('$midShot-webview');
    shot = '${f.path} | ${w.path}';
  }
  await _touch('touchEnd', x0 + dx, y);
  return <String, dynamic>{
    'sawVisible': sawVisible,
    'moveLag': lag.map((double v) => v.round()).toList(),
    'heldLag': heldLag?.round(),
    'mirror': c?.geometry.mirror,
    'shot': shot,
  };
}

Future<void> _keyChecks(WidgetTester tester, _Report r, String wm) async {
  final Map<String, dynamic> p0 = await _settled(tester);
  final Map<String, dynamic> fwd = await _keyTurn(
    tester,
    LogicalKeyboardKey.pageDown,
    midShot: 'curl-key-mid-$wm',
  );
  final Map<String, dynamic> p1 = await _settled(tester);
  r.evidence['$wm/key'] = <String, Object?>{'p0': p0, 'fwd': fwd, 'p1': p1};
  r.check(fwd['sawVisible'] == true, '$wm: key forward showed the curl ($fwd)');
  r.check(
    _int(fwd['distinctX']) >= 4,
    '$wm: curl corner animated across frames ($fwd)',
  );
  _stride = ((p1['pagePos'] as num? ?? 0) - (p0['pagePos'] as num? ?? 0))
      .toDouble();
  final double vw = ((await _js(_configJs))['w'] as num?)?.toDouble() ?? 0;
  r.check(
    _stride.abs() > vw * 0.5 &&
        _stride.abs() < vw * 1.1 &&
        _int(p1['firstChar']) > _int(p0['firstChar']),
    '$wm: key forward = exactly one page (stride $_stride px, viewport $vw, '
    '${p0['firstChar']} -> ${p1['firstChar']})',
  );
  r.check(_clean(p1), '$wm: no residue after forward ($p1)');

  final Map<String, dynamic> back = await _keyTurn(
    tester,
    LogicalKeyboardKey.pageUp,
    midShot: 'curl-key-back-mid-$wm',
  );
  final Map<String, dynamic> p2 = await _settled(tester);
  r.check(back['sawVisible'] == true, '$wm: key back showed the curl ($back)');
  r.check(
    p2['pagePos'] == p0['pagePos'] && p2['firstChar'] == p0['firstChar'],
    '$wm: key back returned to the start page ($p0 -> $p2)',
  );
  r.check(_clean(p2), '$wm: no residue after back ($p2)');

  // 连按：每 60ms 一次，动画远没播完。
  for (int i = 0; i < 5; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _pumpFor(tester, const Duration(milliseconds: 60));
  }
  final Map<String, dynamic> p3 = await _settled(tester);
  r.check(
    _pages(p0, p3) == 5,
    '$wm: 5 rapid forward presses = 5 pages (${p0['pagePos']} -> ${p3['pagePos']})',
  );
  r.check(_clean(p3), '$wm: no residue after rapid forward ($p3)');
  for (int i = 0; i < 5; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await _pumpFor(tester, const Duration(milliseconds: 60));
  }
  final Map<String, dynamic> p4 = await _settled(tester);
  r.check(
    p4['pagePos'] == p0['pagePos'] && p4['firstChar'] == p0['firstChar'],
    '$wm: 5 rapid back presses returned to start (${p0['pagePos']} -> ${p4['pagePos']})',
  );
  r.check(_clean(p4), '$wm: no residue after rapid back ($p4)');
  r.evidence['$wm/rapid'] = <String, Object?>{'p3': p3, 'p4': p4};
}

Future<void> _dragChecks(
  WidgetTester tester,
  _Report r,
  String wm,
  Map<String, dynamic> cfg,
) async {
  final double w = (cfg['w'] as num).toDouble();
  final double h = (cfg['h'] as num).toDouble();
  final bool leftIsForward = cfg['swipeLeftIsForward'] as bool? ?? true;
  final bool mirror = !leftIsForward;
  // 前进方向的手指位移符号与起点（从前进侧页边附近起拖）。
  final double fwd = leftIsForward ? -1 : 1;
  final double fwdStart = leftIsForward ? w * 0.9 : w * 0.1;
  final double backStart = leftIsForward ? w * 0.1 : w * 0.9;

  final Map<String, dynamic> p0 = await _settled(tester);
  final Map<String, dynamic> long = await _drag(
    tester,
    x0: fwdStart,
    y: h * 0.6,
    dx: fwd * w * 0.55,
    width: w,
    mirror: mirror,
    steps: 12,
    stepMs: 32,
    holdMs: 150,
    midShot: 'curl-drag-mid-$wm',
  );
  final Map<String, dynamic> p1 = await _settled(tester);
  r.check(long['sawVisible'] == true, '$wm: long drag showed the curl ($long)');
  r.check(
    long['mirror'] == mirror,
    '$wm: curl mirrored = $mirror (${long['mirror']})',
  );
  final num? heldLag = long['heldLag'] as num?;
  r.check(
    heldLag != null && heldLag < w * 0.03,
    '$wm: corner sits under the finger after hold (lag ${long['heldLag']}px, '
    'per-move ${long['moveLag']})',
  );
  r.check(
    _pages(p0, p1) == 1,
    '$wm: long drag committed one page (${p0['pagePos']} -> ${p1['pagePos']})',
  );
  r.check(_clean(p1), '$wm: no residue after long drag ($p1)');

  final Map<String, dynamic> short = await _drag(
    tester,
    x0: fwdStart,
    y: h * 0.5,
    dx: fwd * w * 0.12,
    width: w,
    mirror: mirror,
    steps: 6,
    stepMs: 100,
    holdMs: 300,
    midShot: 'curl-drag-short-$wm',
  );
  final Map<String, dynamic> p2 = await _settled(tester);
  r.check(
    short['sawVisible'] == true,
    '$wm: short drag showed the curl ($short)',
  );
  r.check(
    p2['pagePos'] == p1['pagePos'] && p2['firstChar'] == p1['firstChar'],
    '$wm: short slow drag curled back, page unchanged ($p1 -> $p2)',
  );
  r.check(_clean(p2), '$wm: no residue after spring-back ($p2)');

  final Map<String, dynamic> back = await _drag(
    tester,
    x0: backStart,
    y: h * 0.4,
    dx: -fwd * w * 0.55,
    width: w,
    mirror: mirror,
    backward: true,
    steps: 12,
    stepMs: 32,
    holdMs: 120,
    midShot: 'curl-drag-back-$wm',
  );
  final Map<String, dynamic> p3 = await _settled(tester);
  r.check(back['sawVisible'] == true, '$wm: back drag showed the curl ($back)');
  final num? backLag = back['heldLag'] as num?;
  r.check(
    backLag != null && backLag < w * 0.03,
    '$wm: back drag fold follows the finger (lag ${back['heldLag']}px, '
    'per-move ${back['moveLag']})',
  );
  r.check(
    p3['pagePos'] == p0['pagePos'] && p3['firstChar'] == p0['firstChar'],
    '$wm: back drag returned one page ($p0 -> $p3)',
  );
  r.check(_clean(p3), '$wm: no residue after back drag ($p3)');

  // 快甩：短距离高速，按速度提交。拦截 JS → Dart 的卷页消息并逐帧记控制器状态。
  await _js(r'''
(function () {
  window.__curlLog = [];
  var b = window.flutter_inappwebview;
  if (b && !b.__curlWrapped) {
    var orig = b.callHandler.bind(b);
    b.callHandler = function (name) {
      if (name === 'onPageCurlDrag' || name === 'onSwipe') {
        window.__curlLog.push(name + ':' + Array.prototype.slice.call(arguments, 1)
          .map(function (v) { return typeof v === 'number' ? Math.round(v * 1000) / 1000 : v; })
          .join(','));
      }
      return orig.apply(null, arguments);
    };
    b.__curlWrapped = true;
  }
  return JSON.stringify({ ok: true });
})()''');
  final Map<String, dynamic> fling = await _drag(
    tester,
    x0: fwdStart,
    y: h * 0.5,
    dx: fwd * w * 0.15,
    width: w,
    mirror: mirror,
    steps: 3,
    stepMs: 16,
    holdMs: 0,
  );
  final List<String> flingPhases = <String>[];
  for (int i = 0; i < 60; i++) {
    final PageCurlController? c = _curl();
    flingPhases.add(
      '${c?.active == true ? 'A' : '-'}${c?.visible == true ? 'V' : '-'}',
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  fling['phases'] = flingPhases.join(' ');
  fling['jsLog'] = (await _js(
    'JSON.stringify({ log: window.__curlLog || [] })',
  ))['log'];
  final Map<String, dynamic> p4 = await _settled(tester);
  r.check(
    _pages(p3, p4) == 1,
    '$wm: quick fling committed one page (${p3['pagePos']} -> ${p4['pagePos']}, $fling)',
  );
  r.check(_clean(p4), '$wm: no residue after fling ($p4)');
  r.evidence['$wm/drag'] = <String, Object?>{
    'p0': p0,
    'long': long,
    'p1': p1,
    'short': short,
    'p2': p2,
    'back': back,
    'p3': p3,
    'fling': fling,
    'p4': p4,
  };
}

Future<void> _chapterChecks(
  WidgetTester tester,
  _Report r,
  String wm,
  Map<String, dynamic> cfg,
) async {
  final bool onShort = await _jump(
    tester,
    _kShortChapter,
    'chapter_01_standard',
  );
  r.check(onShort, '$wm: jumped to short chapter');
  if (!onShort) return;
  // 一路按键前进直到换章。
  String file = (await _js(_positionJs))['file'] as String? ?? '';
  final String startFile = file;
  int presses = 0;
  Map<String, dynamic> last = <String, dynamic>{};
  while (presses < 40 && file == startFile) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    presses++;
    await _pumpFor(tester, const Duration(milliseconds: 200));
    last = await _settled(tester);
    if (_contentReady()) {
      file = last['file'] as String? ?? file;
    } else {
      await _waitFor(tester, _contentReady, polls: 80);
      await _pumpFor(tester, const Duration(milliseconds: 1500));
      last = await _settled(tester);
      file = last['file'] as String? ?? file;
    }
    if (file == startFile && !_clean(last)) {
      r.check(false, '$wm: residue mid-chapter at press $presses ($last)');
      break;
    }
  }
  r.check(
    file != startFile,
    '$wm: key forward crossed into the next chapter after $presses presses ($file)',
  );
  await _js(_installProbesJs);
  final Map<String, dynamic> next0 = await _settled(tester);
  r.check(_clean(next0), '$wm: no residue after chapter cross ($next0)');
  final ObserveShot crossed = await captureReaderWebView('curl-chapter-$wm');

  // 章首后退：回到上一章（末页）。
  await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
  final bool backPrev = await _waitFile(tester, 'chapter_01_standard');
  final Map<String, dynamic> prevEnd = await _settled(tester);
  r.check(
    backPrev,
    '$wm: key back at chapter start returned to previous ($prevEnd)',
  );
  r.check(_clean(prevEnd), '$wm: no residue after chapter back ($prevEnd)');

  // 再前进进下一章，然后在章首做反向拖动 → 回上一章。
  await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
  await _waitFile(tester, file);
  final double w = (cfg['w'] as num).toDouble();
  final double h = (cfg['h'] as num).toDouble();
  final bool leftIsForward = cfg['swipeLeftIsForward'] as bool? ?? true;
  final double fwd = leftIsForward ? -1 : 1;
  final Map<String, dynamic> drag = await _drag(
    tester,
    x0: leftIsForward ? w * 0.1 : w * 0.9,
    y: h * 0.5,
    dx: -fwd * w * 0.55,
    width: w,
    mirror: !leftIsForward,
    steps: 12,
    stepMs: 32,
    holdMs: 100,
  );
  final bool dragPrev = await _waitFile(tester, 'chapter_01_standard');
  final Map<String, dynamic> afterDrag = await _settled(tester);
  r.check(
    dragPrev,
    '$wm: back drag at chapter start returned to previous ($drag, $afterDrag)',
  );
  r.check(_clean(afterDrag), '$wm: no residue after chapter drag ($afterDrag)');
  r.evidence['$wm/chapter'] = <String, Object?>{
    'presses': presses,
    'last': last,
    'next0': next0,
    'crossedShot': crossed.path,
    'prevEnd': prevEnd,
    'drag': drag,
    'afterDrag': afterDrag,
  };
}

Future<void> _run(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  _Report r,
  String wm,
) async {
  await source.setReaderWritingMode(wm);
  await source.setReaderViewMode('paginated');
  await source.setPageTurnAnimation(PageTurnAnimation.curl);
  await source.setPageTurnAnimationSpeed(PageTurnAnimationSpeed.normal);
  await source.setPageTurnFollowDrag(true);
  await _pumpFor(tester, const Duration(milliseconds: 800));
  final bool ready = await _open(tester, bookKey);
  r.check(ready, '$wm: reader ready');
  if (!ready) return;
  r.check(_curl() != null, '$wm: curl overlay mounted');
  final bool onLong = await _jump(tester, _kLongChapter, 'chapter_07_long');
  r.check(onLong, '$wm: jumped to long chapter');
  if (!onLong) return;
  final Map<String, dynamic> cfg = await _js(_configJs);
  r.evidence['$wm/config'] = cfg;
  r.check(
    cfg['effectCfg'] == 'curl' && cfg['followCfg'] == true,
    '$wm: config carries curl + follow ($cfg)',
  );
  // 先往后翻两页，保证后退有余地。
  for (int i = 0; i < 2; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _settled(tester);
  }
  await _keyChecks(tester, r, wm);
  await _dragChecks(tester, r, wm, cfg);
  await _chapterChecks(tester, r, wm, cfg);
  final Map<String, dynamic> errs = await _js(_positionJs);
  r.check(
    (errs['errors'] as List<dynamic>? ?? <dynamic>[]).isEmpty,
    '$wm: no JS errors (${errs['errors']})',
  );
  await _close(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'novel page curl: key turns, rapid turns, follow drag, chapter edges',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'page-curl',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await _pumpFor(tester, const Duration(seconds: 2));
          await readyAppModel(tester);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String baseViewMode = source.readerViewMode;
          final String baseWritingMode = source.readerWritingMode;
          final PageTurnAnimation baseEffect = source.pageTurnAnimation;
          final PageTurnAnimationSpeed baseSpeed =
              source.pageTurnAnimationSpeed;
          final bool baseFollow = source.pageTurnFollowDrag;
          final _Report r = _Report();
          try {
            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'page_turn_animation.epub',
            );
            for (final String wm in <String>['vertical-rl', 'horizontal-tb']) {
              try {
                await _run(tester, source, bookKey, r, wm);
              } catch (e, st) {
                r.check(false, '$wm threw $e\n$st');
                await _close(tester);
              }
            }
          } finally {
            await _close(tester);
            await source.setReaderViewMode(baseViewMode);
            await source.setReaderWritingMode(baseWritingMode);
            await source.setPageTurnAnimation(baseEffect);
            await source.setPageTurnAnimationSpeed(baseSpeed);
            await source.setPageTurnFollowDrag(baseFollow);
          }
          debugPrint('[page-curl] evidence=${jsonEncode(r.evidence)}');
          debugPrint(
            '[page-curl] summary: ${r.failures.length} failure(s)\n'
            '${r.failures.join('\n')}',
          );
          expect(r.failures, isEmpty, reason: r.failures.join('\n'));
        },
      );
    },
  );
}
