import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说阅读器翻页动画（View Transitions 快照翻页 + 拖动跟手）的真 app 回归。
///
/// 真 WebView + 真分页 shell + 真 Dart 翻页链路，竖排（vertical-rl）与横排各一遍：
///
///   1. 翻页模式下平移 / 覆盖 / 淡入三种效果各走一次**真实翻页入口**（键盘 PageDown →
///      Dart `_paginate` → JS `paginate` → `turnPageAnimated`）。为了抓到中途帧，把
///      当前配置的时长经生产热更新入口 `__fushiEngine.updateLive` 临时拉到 2000ms。
///      中途：`html[data-fushi-pt]` 有标记、`document.getAnimations()` 非空，抓帧；
///      结束：标记清掉、首个可见字前进一页、进度可读（`pageTurnBusy` 为假）。
///   2. 拖动跟手：经 CDP `Input.dispatchTouchEvent` 投真实触摸序列（走页面自己的
///      touchstart / touchmove / touchend 监听）。长拖（> 1/4 宽）中途抓帧应看到当前页
///      跟手位移，松手后翻到下一页；慢速短拖（< 1/4 宽）松手回弹、页不变。
///   3. 滚动（continuous）与视觉小说（vn）各开一次：PageDown 正常推进、shell 里没有
///      `turnPageAnimated`、无 JS 异常。
///
/// 设置页三项（翻页动画 / 动画速度 / 拖动跟手）的渲染与非翻页模式置灰由 widget 测试
/// `test/settings/reader_page_turn_animation_settings_test.dart` 覆盖，这里不重复。
///
/// Windows：`powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 integration_test/page_turn_animation_real_app_test.dart`

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

const int _kLongChapter = 6; // chapter_07_long
const int _kSlowDurationMs = 2000;

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
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
    vnIdx: (r && typeof r.currentScreenIndex === 'number') ? r.currentScreenIndex : -1,
    progress: (r && typeof r.calculateProgress === 'function') ? r.calculateProgress() : -1,
    pagePos: (r && typeof r.getPagePosition === 'function' && typeof r.getScrollContext === 'function')
      ? r.getPagePosition(r.getScrollContext()) : null,
    busy: !!(r && typeof r.pageTurnBusy === 'function' && r.pageTurnBusy()),
    stableProgress: (r && !r._reanchorPending &&
      !(r.pageTurnBusy && r.pageTurnBusy()) && window.fushiProgressDetails)
      ? !!window.fushiProgressDetails() : false,
    pt: document.documentElement.getAttribute('data-fushi-pt'),
    anims: document.getAnimations ? document.getAnimations().length : -1,
    bodyTransform: document.body.style.transform || '',
    hasTurnPageAnimated: !!(r && typeof r.turnPageAnimated === 'function'),
    errors: window.__ptErrors || null
  });
})()
''';

/// 动画进行中的读数：标记属性 / 动画列表 / 时长变量。
const String _midJs = r'''
(function () {
  var h = document.documentElement;
  var list = document.getAnimations ? document.getAnimations() : [];
  return JSON.stringify({
    pt: h.getAttribute('data-fushi-pt'),
    move: h.getAttribute('data-fushi-pt-move'),
    oldAnim: h.getAttribute('data-fushi-pt-old'),
    newAnim: h.getAttribute('data-fushi-pt-new'),
    top: h.getAttribute('data-fushi-pt-top'),
    duration: h.style.getPropertyValue('--fushi-pt-duration'),
    anims: list.length,
    detail: list.slice(0, 6).map(function (a) {
      var eff = a.effect || {};
      return (a.animationName || '') + '|' + (eff.pseudoElement || '') + '|' +
        a.playState + '@' + Math.round(Number(a.currentTime) || 0);
    }),
    busy: !!(window.fushiReader && window.fushiReader.pageTurnBusy &&
      window.fushiReader.pageTurnBusy())
  });
})()
''';

const String _configJs = r'''
(function () {
  var C = window.__fushiReaderConfig || {};
  var r = window.fushiReader;
  return JSON.stringify({
    effectCfg: C.pageTurnAnimation, durationCfg: C.pageTurnDurationMs,
    followCfg: C.pageTurnFollowDrag, swipeLeftIsForward: C.swipeLeftIsForward,
    effect: r && r.pageTurnEffect ? r.pageTurnEffect() : null,
    supported: !!(r && r.pageTurnAnimationSupported && r.pageTurnAnimationSupported()),
    followEnabled: !!(r && r.followDragEnabled && r.followDragEnabled()),
    rtl: !!(r && r.pageTurnRtlProgression && r.pageTurnRtlProgression()),
    writingMode: getComputedStyle(document.body).writingMode,
    w: window.innerWidth, h: window.innerHeight
  });
})()
''';

/// 错误 + 触摸事件计数器（开书后装一次；跨章会被新文档清掉）。
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
  if (!window.__ptTouch) {
    window.__ptTouch = { start: 0, move: 0, end: 0 };
    document.addEventListener('touchstart', function () { window.__ptTouch.start++; }, true);
    document.addEventListener('touchmove', function () { window.__ptTouch.move++; }, true);
    document.addEventListener('touchend', function () { window.__ptTouch.end++; }, true);
  }
  return JSON.stringify({ ok: true });
})()
''';

/// 拖动中途：跟手状态、body 平移、正文滚动位置。
const String _dragJs = r'''
(function () {
  var r = window.fushiReader;
  var fd = r && r._followDrag;
  return JSON.stringify({
    active: !!fd,
    mode: fd ? fd.mode : null,
    base: fd ? fd.base : null,
    dx: fd ? fd.dx : null,
    captured: fd ? fd.captured : null,
    shiftPx: fd ? fd.shiftPx : null,
    bodyTransform: document.body.style.transform || '',
    scrollLeft: document.body.scrollLeft, scrollTop: document.body.scrollTop,
    touch: window.__ptTouch || null
  });
})()
''';

class _Report {
  final List<String> failures = <String>[];
  final Map<String, Object?> evidence = <String, Object?>{};

  void check(bool ok, String what) {
    if (!ok) failures.add(what);
    debugPrint('[page-turn] ${ok ? 'ok  ' : 'FAIL'} $what');
  }
}

int _int(Object? v) => (v as num?)?.toInt() ?? -1;

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

/// 生产路径改效果（偏好 setter + 设置页同款 onSettingsChangedLive 热下发），再经
/// 生产热更新入口把时长临时拉长，便于抓中途帧。
Future<Map<String, dynamic>> _applyEffect(
  WidgetTester tester,
  ReaderFushiSource source,
  PageTurnAnimation effect,
) async {
  await source.setPageTurnAnimation(effect);
  ReaderFushiSource.onSettingsChangedLive?.call();
  await _pumpFor(tester, const Duration(milliseconds: 1200));
  await _js(
    'JSON.stringify({ changed: window.__fushiEngine.updateLive('
    '{ pageTurnDurationMs: $_kSlowDurationMs }) })',
  );
  return _js(_configJs);
}

Future<void> _keyTurn(
  WidgetTester tester,
  _Report r,
  String wm,
  PageTurnAnimation effect,
) async {
  final String label = '$wm/${effect.key}';
  final Map<String, dynamic> before = await _js(_positionJs);
  await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
  // 等动画真正起跑（Dart → JS 往返后 data-fushi-pt 才出现）。
  Map<String, dynamic> started = <String, dynamic>{};
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    started = await _js(_midJs);
    if (started['pt'] != null) break;
  }
  r.check(started['pt'] == effect.key, '$label: data-fushi-pt set ($started)');
  // 走到动画大约 1/3 处抓帧。
  await _pumpFor(tester, const Duration(milliseconds: 500));
  final Map<String, dynamic> mid = await _js(_midJs);
  final ObserveShot shot = await captureReaderWebView(
    'pt-mid-$wm-${effect.key}',
  );
  final Map<String, dynamic> midAfterShot = await _js(_midJs);
  r.check(mid['pt'] == effect.key, '$label: mid marker still set ($mid)');
  r.check(_int(mid['anims']) > 0, '$label: getAnimations non-empty mid-turn');
  r.check(shot.saved && shot.nonBlank, '$label: mid frame captured');
  await _pumpFor(tester, const Duration(milliseconds: 2600));
  final Map<String, dynamic> after = await _js(_positionJs);
  final ObserveShot end = await captureReaderWebView(
    'pt-end-$wm-${effect.key}',
  );
  r.evidence[label] = <String, Object?>{
    'before': before,
    'started': started,
    'mid': mid,
    'midAfterShot': midAfterShot,
    'after': after,
    'midShot': shot.path,
    'endShot': end.path,
  };
  r.check(after['pt'] == null, '$label: marker cleared after animation');
  r.check(_int(after['anims']) == 0, '$label: no animations left');
  r.check(
    _int(after['firstChar']) > _int(before['firstChar']),
    '$label: advanced (${before['firstChar']} -> ${after['firstChar']})',
  );
  r.check(
    after['file'] == before['file'],
    '$label: stayed in chapter (${after['file']})',
  );
  r.check(
    after['busy'] == false && after['stableProgress'] == true,
    '$label: progress readable after turn',
  );
  r.check(
    ((after['progress'] as num?) ?? -1) > ((before['progress'] as num?) ?? 2),
    '$label: progress grew (${before['progress']} -> ${after['progress']})',
  );
}

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

/// 一次拖动：起点视口中心，按 [steps] 步移到 [dx]，每步间隔 [stepMs]。
/// [midShot] 非空时在最后一步后、松手前抓帧。
Future<Map<String, dynamic>> _drag(
  WidgetTester tester, {
  required double cx,
  required double cy,
  required double dx,
  required int steps,
  required int stepMs,
  required int holdMs,
  String? midShot,
}) async {
  await _touch('touchStart', cx, cy);
  await _pumpFor(tester, Duration(milliseconds: stepMs));
  for (int i = 1; i <= steps; i++) {
    await _touch('touchMove', cx + dx * i / steps, cy);
    await _pumpFor(tester, Duration(milliseconds: stepMs));
  }
  await _pumpFor(tester, Duration(milliseconds: holdMs));
  final Map<String, dynamic> mid = await _js(_dragJs);
  String? shotPath;
  if (midShot != null) {
    final ObserveShot shot = await captureReaderWebView(midShot);
    shotPath = shot.saved && shot.nonBlank ? shot.path : null;
  }
  await _touch('touchEnd', cx + dx, cy);
  return <String, dynamic>{'mid': mid, 'shot': shotPath};
}

Future<void> _dragChecks(
  WidgetTester tester,
  ReaderFushiSource source,
  _Report r,
  String wm,
  PageTurnAnimation effect,
) async {
  final String label = '$wm/drag-${effect.key}';
  final Map<String, dynamic> cfg = await _applyEffect(tester, source, effect);
  r.evidence['$label/config'] = cfg;
  r.check(cfg['followEnabled'] == true, '$label: follow drag enabled ($cfg)');
  if (cfg['followEnabled'] != true) return;
  await _js(_installProbesJs);
  final double w = (cfg['w'] as num).toDouble();
  final double h = (cfg['h'] as num).toDouble();
  final bool leftIsForward =
      cfg['swipeLeftIsForward'] as bool? ?? !wm.startsWith('vertical');
  final double fwd = leftIsForward ? -1 : 1;

  // 长拖：0.4 宽，跟手中途抓帧，松手翻到下一页。
  final Map<String, dynamic> before = await _js(_positionJs);
  final Map<String, dynamic> long = await _drag(
    tester,
    cx: w / 2,
    cy: h / 2,
    dx: fwd * w * 0.4,
    steps: 8,
    stepMs: 40,
    holdMs: 150,
    midShot: 'pt-drag-mid-$wm-${effect.key}',
  );
  final Map<String, dynamic> mid = long['mid'] as Map<String, dynamic>;
  final Map<String, dynamic> touchCount = Map<String, dynamic>.from(
    mid['touch'] as Map? ?? <String, dynamic>{},
  );
  r.check(
    _int(touchCount['start']) > 0 && _int(touchCount['move']) > 0,
    '$label: CDP touch reached page listeners ($touchCount)',
  );
  r.check(mid['active'] == true, '$label: follow drag active mid-drag ($mid)');
  final bool displaced = mid['mode'] == 'scroll'
      ? _int(mid['captured']) > w * 0.3
      : (mid['bodyTransform'] as String? ?? '').contains('translateX') &&
            ((mid['shiftPx'] as num?)?.abs() ?? 0) > w * 0.3;
  r.check(displaced, '$label: current page follows the finger ($mid)');
  r.check(long['shot'] != null, '$label: mid-drag frame captured');
  await _pumpFor(tester, const Duration(milliseconds: 2800));
  final Map<String, dynamic> afterLong = await _js(_positionJs);
  final ObserveShot endLong = await captureReaderWebView(
    'pt-drag-end-$wm-${effect.key}',
  );
  r.check(
    _int(afterLong['firstChar']) > _int(before['firstChar']),
    '$label: long drag turned to next page '
    '(${before['firstChar']} -> ${afterLong['firstChar']})',
  );
  r.check(
    afterLong['pt'] == null &&
        afterLong['bodyTransform'] == '' &&
        afterLong['busy'] == false,
    '$label: long drag left no residue ($afterLong)',
  );

  // 短拖：0.12 宽、慢速，停住再松手 → 回弹、页不变。
  final Map<String, dynamic> short = await _drag(
    tester,
    cx: w / 2,
    cy: h / 2,
    dx: fwd * w * 0.12,
    steps: 6,
    stepMs: 120,
    holdMs: 300,
    midShot: 'pt-drag-short-mid-$wm-${effect.key}',
  );
  await _pumpFor(tester, const Duration(milliseconds: 2000));
  final Map<String, dynamic> afterShort = await _js(_positionJs);
  r.check(
    (short['mid'] as Map<String, dynamic>)['active'] == true,
    '$label: short drag entered follow mode (${short['mid']})',
  );
  r.check(
    afterShort['firstChar'] == afterLong['firstChar'] &&
        afterShort['pagePos'] == afterLong['pagePos'],
    '$label: short drag sprang back '
    '(${afterLong['firstChar']}/${afterLong['pagePos']} -> '
    '${afterShort['firstChar']}/${afterShort['pagePos']})',
  );
  r.check(
    afterShort['bodyTransform'] == '' && afterShort['busy'] == false,
    '$label: rebound left no residue ($afterShort)',
  );
  r.evidence[label] = <String, Object?>{
    'before': before,
    'longMid': mid,
    'longShot': long['shot'],
    'afterLong': afterLong,
    'endLongShot': endLong.path,
    'shortMid': short['mid'],
    'shortShot': short['shot'],
    'afterShort': afterShort,
  };
}

Future<void> _paginatedRun(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  _Report r,
  String wm,
) async {
  await source.setReaderWritingMode(wm);
  await source.setReaderViewMode('paginated');
  await source.setPageTurnAnimation(PageTurnAnimation.slide);
  await source.setPageTurnAnimationSpeed(PageTurnAnimationSpeed.slow);
  await source.setPageTurnFollowDrag(true);
  await _pumpFor(tester, const Duration(milliseconds: 800));
  final bool ready = await _open(tester, bookKey);
  r.check(ready, '$wm: paginated reader ready');
  if (!ready) return;
  final bool onLong = await _jump(tester, _kLongChapter, 'chapter_07_long');
  r.check(onLong, '$wm: jumped to long chapter');
  if (!onLong) return;
  await _js(_installProbesJs);
  for (final PageTurnAnimation effect in <PageTurnAnimation>[
    PageTurnAnimation.slide,
    PageTurnAnimation.cover,
    PageTurnAnimation.fade,
  ]) {
    final Map<String, dynamic> cfg = await _applyEffect(tester, source, effect);
    r.evidence['$wm/${effect.key}/config'] = cfg;
    r.check(
      cfg['effect'] == effect.key &&
          _int(cfg['durationCfg']) == _kSlowDurationMs,
      '$wm/${effect.key}: config live-updated ($cfg)',
    );
    r.check(cfg['supported'] == true, '$wm: startViewTransition supported');
    await _keyTurn(tester, r, wm, effect);
  }
  // 竖排用覆盖（shift 模式），横排用平移（scroll 模式）：两种跟手实现各一遍。
  await _dragChecks(
    tester,
    source,
    r,
    wm,
    wm.startsWith('vertical')
        ? PageTurnAnimation.cover
        : PageTurnAnimation.slide,
  );
  final Map<String, dynamic> errs = await _js(_positionJs);
  r.check(
    (errs['errors'] as List<dynamic>? ?? <dynamic>[]).isEmpty,
    '$wm: no JS errors (${errs['errors']})',
  );
  await _close(tester);
}

Future<void> _otherModeRun(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  _Report r,
  String viewMode,
) async {
  await source.setReaderWritingMode('vertical-rl');
  await source.setReaderViewMode(viewMode);
  await source.setPageTurnAnimation(PageTurnAnimation.slide);
  await _pumpFor(tester, const Duration(milliseconds: 800));
  final bool ready = await _open(tester, bookKey);
  r.check(ready, '$viewMode: reader ready');
  if (!ready) return;
  final bool onLong = await _jump(tester, _kLongChapter, 'chapter_07_long');
  r.check(onLong, '$viewMode: jumped to long chapter');
  await _js(_installProbesJs);
  final Map<String, dynamic> before = await _js(_positionJs);
  final Map<String, dynamic> se = await _js(
    'JSON.stringify({ sx: (document.scrollingElement||document.documentElement).scrollLeft, '
    'sy: (document.scrollingElement||document.documentElement).scrollTop, '
    'bx: document.body.scrollLeft, by: document.body.scrollTop })',
  );
  for (int i = 0; i < 2; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _pumpFor(tester, const Duration(milliseconds: 900));
  }
  await _pumpFor(tester, const Duration(milliseconds: 800));
  final Map<String, dynamic> after = await _js(_positionJs);
  final Map<String, dynamic> se2 = await _js(
    'JSON.stringify({ sx: (document.scrollingElement||document.documentElement).scrollLeft, '
    'sy: (document.scrollingElement||document.documentElement).scrollTop, '
    'bx: document.body.scrollLeft, by: document.body.scrollTop })',
  );
  final ObserveShot shot = await captureReaderWebView('pt-$viewMode-after');
  r.evidence[viewMode] = <String, Object?>{
    'before': before,
    'after': after,
    'scrollBefore': se,
    'scrollAfter': se2,
    'shot': shot.path,
  };
  final bool advanced = viewMode == 'vn'
      ? _int(after['vnIdx']) > _int(before['vnIdx'])
      : _int(after['firstChar']) > _int(before['firstChar']) ||
            jsonEncode(se) != jsonEncode(se2);
  r.check(advanced, '$viewMode: PageDown advanced ($before -> $after)');
  r.check(
    after['hasTurnPageAnimated'] == false,
    '$viewMode: shell has no turnPageAnimated',
  );
  r.check(after['pt'] == null, '$viewMode: no page-turn marker');
  r.check(
    (after['errors'] as List<dynamic>? ?? <dynamic>[]).isEmpty,
    '$viewMode: no JS errors (${after['errors']})',
  );
  await _close(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'novel page-turn animation: key turns, follow drag, other modes',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'page-turn',
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
                await _paginatedRun(tester, source, bookKey, r, wm);
              } catch (e, st) {
                r.check(false, '$wm threw $e\n$st');
                await _close(tester);
              }
            }
            for (final String vm in <String>['continuous', 'vn']) {
              try {
                await _otherModeRun(tester, source, bookKey, r, vm);
              } catch (e, st) {
                r.check(false, '$vm threw $e\n$st');
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
          debugPrint('[page-turn] evidence=${jsonEncode(r.evidence)}');
          debugPrint(
            '[page-turn] summary: ${r.failures.length} failure(s)\n'
            '${r.failures.join('\n')}',
          );
          expect(r.failures, isEmpty, reason: r.failures.join('\n'));
        },
      );
    },
  );
}
