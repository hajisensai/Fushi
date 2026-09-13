import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/reader_status_footer.dart'
    show kReaderStatusFooterHeight;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2471 / BUG-2470 真 app 证据（Windows 离屏 runner / Mac 跨机，真 WebView + 真引擎）。
///
/// A. BUG-2471 —— 开着阅读器改「上边距」偏好（与设置页 slider 同一 setter
///    `setReaderMarginTop` → `onSettingsChangedLive`）必须**不重载章节**就生效：
///      1. 基线：`--reader-margin-top` 内联像素变量、body padding-top、
///         `window.__fushiReaderConfig.marginTop`、导航代数；
///      2. 把上边距改成基线 + 10 个百分点；
///      3. 断言像素变量 == 视口高 × 新百分比（±1px）、config 已是新值、body padding-top
///         跟着长了同样的像素，且导航代数没变（不是靠整章重载生效的）；
///      4. 改回基线，断言回到基线值。
///    修复前第 3 步必红：像素变量停在 install 时物化的旧值（BUG-1812 之后一直如此）。
///    顺带断言滑动灵敏度 / 滚轮静默窗 / 扫描非日文也热更新进了 config。
///
/// B. BUG-2470 —— 状态行贴屏底：`fushi_status_footer` 的底边 == 窗口底边，带高 ==
///    max(状态行高, 系统底 inset)（桌面 inset 0 → 28）。iPhone 上带高应为 34 而不是
///    62，那一半只能在 iOS 模拟器 / 真机上量（同一份测试）。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_live_settings_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const Key _kStatusFooterKey = ValueKey<String>('fushi_status_footer');

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) {
      debugPrint(
        '[live-settings] $label ready after ${i * step.inMilliseconds}ms',
      );
      return;
    }
  }
  fail(
    '$label did not become ready within '
    '${maxPolls * step.inMilliseconds}ms',
  );
}

class _Probe {
  const _Probe({
    required this.marginTopPx,
    required this.paddingTop,
    required this.configMarginTop,
    required this.configSwipeDist,
    required this.configWheelQuiet,
    required this.scanNonJapanese,
    required this.viewportH,
    required this.navGeneration,
    required this.reanchorPending,
  });

  factory _Probe.fromJson(Map<String, dynamic> m) => _Probe(
        marginTopPx: (m['marginTopPx'] as num).toDouble(),
        paddingTop: (m['padT'] as num).toDouble(),
        configMarginTop: (m['cfgMarginTop'] as num?)?.toDouble() ?? -1,
        configSwipeDist: (m['cfgSwipeDist'] as num?)?.toInt() ?? -1,
        configWheelQuiet: (m['cfgWheelQuiet'] as num?)?.toInt() ?? -1,
        scanNonJapanese: m['scanNonJapanese'],
        viewportH: (m['viewportH'] as num).toDouble(),
        navGeneration: (m['nav'] as num?)?.toInt() ?? -1,
        reanchorPending: m['pending'] == true,
      );

  final double marginTopPx;
  final double paddingTop;
  final double configMarginTop;
  final int configSwipeDist;
  final int configWheelQuiet;
  final Object? scanNonJapanese;
  final double viewportH;
  final int navGeneration;
  final bool reanchorPending;

  @override
  String toString() =>
      'marginTopPx=$marginTopPx padT=$paddingTop cfgMarginTop=$configMarginTop '
      'cfgSwipeDist=$configSwipeDist cfgWheelQuiet=$configWheelQuiet '
      'scanNonJapanese=$scanNonJapanese viewportH=$viewportH nav=$navGeneration '
      'pending=$reanchorPending';
}

const String _probeJs = r'''
(function () {
  var root = document.documentElement;
  var rs = getComputedStyle(root);
  var bs = getComputedStyle(document.body);
  var C = window.__fushiReaderConfig || {};
  var r = window.fushiReader;
  var last = window.__fushiReaderMarginsLast || {};
  return JSON.stringify({
    marginTopPx: parseFloat(root.style.getPropertyValue('--reader-margin-top')) || 0,
    padT: parseFloat(bs.paddingTop) || 0,
    cfgMarginTop: C.marginTop,
    cfgSwipeDist: C.swipeDistThreshold,
    cfgWheelQuiet: C.wheelGestureQuietMs,
    scanNonJapanese: window.scanNonJapaneseText,
    viewportH: last.h || C.dartPageHeight || 0,
    nav: C.navigationGeneration,
    pending: !!(r && r._reanchorPending === true)
  });
})()
''';

typedef _RunJs = Future<dynamic> Function(String source);

Future<_Probe> _probe(_RunJs runJs) async {
  final Object? raw = await runJs(_probeJs);
  final Map<String, dynamic> m = raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
  return _Probe.fromJson(m);
}

/// 轮询到重锚落地且读数连续两次不变。
Future<_Probe> _settled(WidgetTester tester, _RunJs runJs, String label) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  _Probe? last;
  for (int i = 0; i < 30; i++) {
    final _Probe now = await _probe(runJs);
    if (!now.reanchorPending &&
        last != null &&
        !last.reanchorPending &&
        last.marginTopPx == now.marginTopPx &&
        last.paddingTop == now.paddingTop &&
        last.configMarginTop == now.configMarginTop) {
      debugPrint('[live-settings] $label: $now');
      return now;
    }
    last = now;
    await tester.pump(const Duration(milliseconds: 200));
  }
  debugPrint('[live-settings] $label (not fully settled): $last');
  return last!;
}

Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final ObserveShot frame = await captureFlutterFrame(tester, name);
  debugPrint(
    '[live-settings] frame $name saved=${frame.saved} '
    'nonBlank=${frame.nonBlank} path=${frame.path}',
  );
  final ObserveShot web = await captureReaderWebView('$name-webview');
  debugPrint(
    '[live-settings] webview $name saved=${web.saved} '
    'nonBlank=${web.nonBlank} path=${web.path}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2471: margin / gesture settings hot-update the running engine; '
    'BUG-2470: status footer sits on the screen bottom inside the safe area',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'live-settings',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home (nav bar) must render',
          );
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final ReaderFushiSource source = ReaderFushiSource.instance;

          final double baseMarginTop = source.readerMarginTop;
          final double baseSwipe = source.swipePageTurnSensitivity;
          final int baseWheel = source.wheelPageTurnInterval;
          final bool baseScan = appModel.scanNonJapaneseText;
          try {
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderViewMode('paginated');
            await _pumpForPref(tester);

            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'bug2461_live_settings.epub',
            );
            await openBookViaProductionPath(tester, bookKey);
            await _waitFor(tester, _webViewShown, 'reader WebView');
            await _waitFor(tester, _contentReady, 'reader content');
            await _waitFor(
              tester,
              readerWebViewReady,
              'reader debug hooks',
              maxPolls: 20,
            );
            await tester.pump(const Duration(seconds: 2));

            final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
            expect(runJs, isNotNull, reason: 'reader must expose the JS hook');

            // ── B. BUG-2470：状态行贴屏底、带高 = max(28, 系统底 inset) ──
            final Finder footer = find.byKey(_kStatusFooterKey);
            expect(footer, findsOneWidget, reason: '悬浮态下状态行常驻');
            final Rect footerRect = tester.getRect(footer);
            final Size screen =
                tester.view.physicalSize / tester.view.devicePixelRatio;
            final double bottomInset = MediaQuery.viewPaddingOf(
              tester.element(find.byType(ReaderFushiPage)),
            ).bottom;
            final double expectedBand = bottomInset > kReaderStatusFooterHeight
                ? bottomInset
                : kReaderStatusFooterHeight;
            debugPrint(
              '[live-settings] footer rect=$footerRect screen=$screen '
              'bottomInset=$bottomInset expectedBand=$expectedBand',
            );
            expect(
              (footerRect.bottom - screen.height).abs(),
              lessThan(0.5),
              reason: '状态行底边必须贴窗口底边（坐进安全区），不是浮在 inset 之上',
            );
            expect(
              (footerRect.height - expectedBand).abs(),
              lessThan(0.5),
              reason: '带高 = max(状态行高, 系统底 inset)',
            );

            // ── A. BUG-2471：改上边距，不重载章节就生效 ──────────────────
            final _Probe base = await _settled(tester, runJs!, 'baseline');
            expect(base.navGeneration, isNonNegative);
            expect(base.viewportH, greaterThan(0));
            expect(base.configMarginTop, closeTo(baseMarginTop, 0.001));
            expect(
              base.marginTopPx,
              closeTo(base.viewportH * baseMarginTop / 100, 1.0),
              reason: 'install 时的物化像素 = 视口高 × 百分比',
            );
            await _capture(tester, 'live-01-baseline');

            final double newMarginTop = baseMarginTop + 10;
            await source.setReaderMarginTop(newMarginTop);
            await _pumpForPref(tester);
            final _Probe changed = await _settled(tester, runJs, 'after +10%');
            await _capture(tester, 'live-02-margin-plus10');
            expect(
              changed.navGeneration,
              base.navGeneration,
              reason: '必须是热更新，不是靠整章重载（导航代数不能变）',
            );
            expect(
              changed.configMarginTop,
              closeTo(newMarginTop, 0.001),
              reason: 'updateLive 必须把新百分比合并进 __fushiReaderConfig',
            );
            expect(
              changed.marginTopPx,
              closeTo(changed.viewportH * newMarginTop / 100, 1.0),
              reason: '--reader-margin-top 像素变量必须按新百分比重物化',
            );
            final double expectedDelta =
                changed.viewportH * (newMarginTop - baseMarginTop) / 100;
            expect(
              changed.paddingTop - base.paddingTop,
              closeTo(expectedDelta, 1.5),
              reason: 'body padding-top 是用户看得见的落点，必须跟着长',
            );

            // 其余热更新键。
            await source.setSwipePageTurnSensitivity(baseSwipe * 2);
            await source.setWheelPageTurnInterval(baseWheel + 100);
            await appModel.setScanNonJapaneseText(!baseScan);
            ReaderFushiSource.onSettingsChangedLive?.call();
            await _pumpForPref(tester);
            final _Probe gestures = await _settled(tester, runJs, 'gestures');
            expect(
              gestures.configSwipeDist,
              isNot(base.configSwipeDist),
              reason: '滑动灵敏度阈值必须热更新',
            );
            expect(
              gestures.configWheelQuiet,
              (baseWheel + 100).clamp(150, 800),
              reason: '滚轮静默窗必须热更新',
            );
            expect(
              gestures.scanNonJapanese,
              !baseScan,
              reason: 'window.scanNonJapaneseText 必须镜像新值',
            );

            // 改回基线。
            await source.setReaderMarginTop(baseMarginTop);
            await _pumpForPref(tester);
            final _Probe restored = await _settled(tester, runJs, 'restored');
            expect(restored.marginTopPx, closeTo(base.marginTopPx, 1.0));
            expect(restored.paddingTop, closeTo(base.paddingTop, 1.5));
            expect(restored.navGeneration, base.navGeneration);
          } finally {
            await source.setReaderMarginTop(baseMarginTop);
            await source.setSwipePageTurnSensitivity(baseSwipe);
            await source.setWheelPageTurnInterval(baseWheel);
            await appModel.setScanNonJapaneseText(baseScan);
            await _pumpForPref(tester);
            if (!_readerPageGone()) {
              final NavigatorState nav = Navigator.of(
                tester.element(find.byType(ReaderFushiPage)),
              );
              nav.pop();
              await _waitFor(
                tester,
                _readerPageGone,
                'reader closed',
                maxPolls: 40,
              );
            }
          }
        },
      );
    },
  );
}
