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
import 'package:fushi_audio/fushi_audio.dart' show AudiobookPlayerController;

import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedAudiobook,
        seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2468 / BUG-2467 真 app 证据（Windows 离屏 runner，真 WebView2 + 真分页 JS）。
///
/// A. BUG-2468 —— 竖排分页 shell 的 `window.fushiReader.setChromeInsets(top, bottom)`
///    过去只改 `--chrome-top/bottom-inset` 与列高，不重算 `--fushi-image-max-height`，
///    于是 chrome inset 变化后整页插图比列高多出一条 chrome 高、被 Blink 切到相邻列。
///    修复后 `setChromeInsets` 调 `_resetImageMaxVars()`。这里在真阅读器里：
///      1. 记录基线 `--fushi-image-max-height` / body `columnWidth` / 两条 inset；
///      2. 调 `setChromeInsets(48, 84)`，等重锚落地；
///      3. 断言 max-height == 新 columnWidth（±1px）且比基线缩小了
///         `(48 + 84) − (基线 top + 基线 bottom)`；
///      4. 调 `setChromeInsets(基线 top, 基线 bottom)` 复原，再断言相等且回到基线。
///    修复前第 3 步必红（max-height 停在基线值，比新列高多 132 − 基线 inset 和）。
///    证据不依赖任何插图存在——被测的是 CSS 变量与列高的同步关系。
///
/// B. BUG-2467 —— 桌面端底栏挤压模式（`tap_empty_hide_chrome=false`）下状态行
///    （`fushi_status_footer`）与有声书播放条（`fushi_play_bar`）右端曾重复画同一串
///    读数。修复后挤压态底栏占位时状态行不画。这里把偏好设为 false、开一本挂了有声书
///    的书、等播放条出现，断言播放条内联读数（`fushi_bar_status_progress`）在场而
///    状态行及其读数（`fushi_status_progress`）不在场；再把偏好设回 true（悬浮态）+
///    `onChromeReanchorLive`，断言状态行回来。改过的偏好在 `finally` 里还原。
///
/// 全程不点控件：开书走 [openBookViaProductionPath]（与书卡 onTap 同一 `openMedia`），
/// 其余经 debug 钩子 / JS。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_chrome_inset_image_box_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const Key _kPlayBarKey = ValueKey<String>('fushi_play_bar');
const Key _kBarProgressKey = ValueKey<String>('fushi_bar_status_progress');
const Key _kStatusFooterKey = ValueKey<String>('fushi_status_footer');
const Key _kEdgeLineKey = ValueKey<String>('fushi_progress_edge_line');
const Key _kFooterProgressKey = ValueKey<String>('fushi_status_progress');

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
          '[inset-probe] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail('$label did not become ready within '
      '${maxPolls * step.inMilliseconds}ms');
}

/// 一次 DOM 采样：图片 max 盒、body used column-width、两条 chrome inset，以及
/// 分页 shell 的重锚在飞旗（采样必须等它落下，否则读到的是过渡态）。
class _InsetProbe {
  const _InsetProbe({
    required this.maxWidth,
    required this.maxHeight,
    required this.columnWidth,
    required this.columnWidthRaw,
    required this.topInset,
    required this.bottomInset,
    required this.bodyClientHeight,
    required this.paddingTop,
    required this.paddingBottom,
    required this.vertical,
    required this.reanchorPending,
  });

  factory _InsetProbe.fromJson(Map<String, dynamic> m) => _InsetProbe(
        maxWidth: (m['maxW'] as num).toDouble(),
        maxHeight: (m['maxH'] as num).toDouble(),
        columnWidth: (m['colW'] as num).toDouble(),
        columnWidthRaw: m['colWRaw'].toString(),
        topInset: (m['top'] as num).toDouble(),
        bottomInset: (m['bottom'] as num).toDouble(),
        bodyClientHeight: (m['bodyClientH'] as num).toDouble(),
        paddingTop: (m['padT'] as num).toDouble(),
        paddingBottom: (m['padB'] as num).toDouble(),
        vertical: m['vertical'] == true,
        reanchorPending: m['pending'] == true,
      );

  final double maxWidth;
  final double maxHeight;
  final double columnWidth;
  final String columnWidthRaw;
  final double topInset;
  final double bottomInset;
  final double bodyClientHeight;
  final double paddingTop;
  final double paddingBottom;
  final bool vertical;
  final bool reanchorPending;

  @override
  String toString() =>
      'maxH=${_f(maxHeight)} colW=${_f(columnWidth)} ($columnWidthRaw) '
      'maxW=${_f(maxWidth)} top=${_f(topInset)} bottom=${_f(bottomInset)} '
      'bodyClientH=${_f(bodyClientHeight)} padT=${_f(paddingTop)} '
      'padB=${_f(paddingBottom)} vertical=$vertical pending=$reanchorPending';
}

const String _probeJs = r'''
(function () {
  var rs = getComputedStyle(document.documentElement);
  var bs = getComputedStyle(document.body);
  var r = window.fushiReader;
  return JSON.stringify({
    maxW: parseFloat(rs.getPropertyValue('--fushi-image-max-width')) || 0,
    maxH: parseFloat(rs.getPropertyValue('--fushi-image-max-height')) || 0,
    colW: parseFloat(bs.columnWidth) || 0,
    colWRaw: String(bs.columnWidth),
    top: parseFloat(rs.getPropertyValue('--chrome-top-inset')) || 0,
    bottom: parseFloat(rs.getPropertyValue('--chrome-bottom-inset')) || 0,
    bodyClientH: document.body.clientHeight,
    padT: parseFloat(bs.paddingTop) || 0,
    padB: parseFloat(bs.paddingBottom) || 0,
    vertical: !!(r && r.isVertical && r.isVertical()),
    pending: !!(r && r._reanchorPending === true)
  });
})()
''';

typedef _RunJs = Future<dynamic> Function(String source);

Future<_InsetProbe> _probe(_RunJs runJs) async {
  final Object? raw = await runJs(_probeJs);
  final Map<String, dynamic> m = raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
  return _InsetProbe.fromJson(m);
}

/// 等两帧让 JS 侧 rAF 重锚跑完，再轮询到 `_reanchorPending` 落下且读数连续两次
/// 不变（inset 下发 → reflow → 重锚是异步链，采样过渡态会把真值误判成红）。
Future<_InsetProbe> _settledProbe(
  WidgetTester tester,
  _RunJs runJs,
  String label,
) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  _InsetProbe? last;
  for (int i = 0; i < 30; i++) {
    final _InsetProbe now = await _probe(runJs);
    if (!now.reanchorPending &&
        last != null &&
        !last.reanchorPending &&
        last.maxHeight == now.maxHeight &&
        last.columnWidth == now.columnWidth &&
        last.bottomInset == now.bottomInset &&
        last.topInset == now.topInset) {
      debugPrint('[inset-probe] $label: $now');
      return now;
    }
    last = now;
    await tester.pump(const Duration(milliseconds: 200));
  }
  debugPrint('[inset-probe] $label (not fully settled): $last');
  return last!;
}

/// 让 fire-and-forget 的偏好 setter 落地。
Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _openSeededBook(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, 'reader WebView');
  await _waitFor(tester, _contentReady, 'reader content');
  await _waitFor(tester, readerWebViewReady, 'reader debug hooks',
      maxPolls: 20);
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  final NavigatorState nav =
      Navigator.of(tester.element(find.byType(ReaderFushiPage)));
  nav.pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _capture(WidgetTester tester, String name) async {
  final ObserveShot frame = await captureFlutterFrame(tester, name);
  debugPrint('[inset-probe] frame $name saved=${frame.saved} '
      'nonBlank=${frame.nonBlank} path=${frame.path}');
  final ObserveShot web = await captureReaderWebView('$name-webview');
  debugPrint('[inset-probe] webview $name saved=${web.saved} '
      'nonBlank=${web.nonBlank} path=${web.path}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2468: setChromeInsets re-derives the image max box to the new column '
    'height; BUG-2467: squeeze-mode play bar absorbs the status footer',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'inset-probe',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          // ── A. BUG-2468：竖排分页（非连续） ────────────────────────────
          // 隔离根上这两项本就是默认值；显式写一遍让证据不依赖默认值不变。
          await ReaderFushiSource.instance.setReaderWritingMode('vertical-rl');
          await ReaderFushiSource.instance.setReaderViewMode('paginated');
          await _pumpForPref(tester);

          final String bookKey = await seedReaderBook(tester,
              fileName: 'bug2454_vertical_paginated.epub');
          await _openSeededBook(tester, bookKey);
          // 首次就绪后页面会补发一次 chrome insets（_reapplyChromeInsetsAfterFirstLoad）
          // 并重锚；基线必须取在那之后。
          await tester.pump(const Duration(seconds: 2));

          final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull,
              reason:
                  'reader must expose debugEvaluateJavascript (debug build)');
          expect(ReaderFushiSource.readerSettings?.isContinuousMode, isFalse,
              reason: 'A must run in paginated (non-continuous) mode');

          final _InsetProbe base =
              await _settledProbe(tester, runJs!, 'A.1 baseline');
          expect(base.vertical, isTrue,
              reason: 'A must run in vertical-rl (fushiReader.isVertical())');
          expect(base.columnWidth, greaterThan(0),
              reason: 'paginated body must have a used column-width '
                  '(got ${base.columnWidthRaw})');
          expect(base.maxHeight, closeTo(base.columnWidth, 1.0),
              reason: 'A.1 baseline: image max-height must already equal the '
                  'column height after the first-load inset re-send');
          await _capture(tester, 'observe-a1-baseline');

          // A.2：改 chrome inset（顶栏 48 + 底栏 84），等重锚落地。
          await runJs('window.fushiReader.setChromeInsets(48, 84);');
          final _InsetProbe grown = await _settledProbe(
              tester, runJs, 'A.3 after setChromeInsets(48,84)');
          expect(grown.topInset, closeTo(48, 0.5));
          expect(grown.bottomInset, closeTo(84, 0.5));
          final double expectedShrink =
              (48 + 84) - (base.topInset + base.bottomInset);
          debugPrint('[inset-probe] A.3 maxH ${_f(base.maxHeight)} → '
              '${_f(grown.maxHeight)} (Δ=${_f(base.maxHeight - grown.maxHeight)}, '
              'expected ≈ ${_f(expectedShrink)}); colW ${_f(base.columnWidth)} → '
              '${_f(grown.columnWidth)}');
          expect(grown.columnWidth,
              closeTo(base.columnWidth - expectedShrink, 1.0),
              reason: 'sanity: the column height itself must shrink by the '
                  'inset delta (CSS column-width reads the inset vars)');
          // 根因断言：修复前 --fushi-image-max-height 停在基线值（比新列高多
          // expectedShrink px），插图因此被 Blink 切到相邻列。
          expect(grown.maxHeight, closeTo(grown.columnWidth, 1.0),
              reason:
                  'BUG-2468: after setChromeInsets the image max-height must '
                  'be re-derived to the NEW column height '
                  '(maxH=${_f(grown.maxHeight)} colW=${_f(grown.columnWidth)} '
                  'baseline maxH=${_f(base.maxHeight)})');
          expect(base.maxHeight - grown.maxHeight, closeTo(expectedShrink, 2.0),
              reason: 'BUG-2468: max-height must shrink by exactly the inset '
                  'delta (${_f(expectedShrink)}px)');
          await _capture(tester, 'observe-a3-insets-48-84');

          // A.4：复原到基线 inset，再断言相等且回到基线。
          await runJs('window.fushiReader.setChromeInsets('
              '${base.topInset}, ${base.bottomInset});');
          final _InsetProbe restored = await _settledProbe(
              tester, runJs, 'A.4 after restoring baseline insets');
          expect(restored.topInset, closeTo(base.topInset, 0.5));
          expect(restored.bottomInset, closeTo(base.bottomInset, 0.5));
          expect(restored.maxHeight, closeTo(restored.columnWidth, 1.0),
              reason: 'BUG-2468: restoring the insets must re-derive the image '
                  'max-height again');
          expect(restored.maxHeight, closeTo(base.maxHeight, 1.0),
              reason: 'restored max-height must return to the baseline value');
          await _capture(tester, 'observe-a4-insets-restored');
          debugPrint('[inset-probe] A PASS: maxH tracks columnWidth through '
              '${_f(base.maxHeight)} → ${_f(grown.maxHeight)} → '
              '${_f(restored.maxHeight)}');

          await _closeReader(tester);

          // ── B. BUG-2467：挤压态底栏吸收状态行 ──────────────────────────
          final bool originalTapEmpty =
              ReaderFushiSource.instance.tapEmptyToHideChrome;
          debugPrint('[inset-probe] B tap_empty_hide_chrome original='
              '$originalTapEmpty');
          try {
            if (originalTapEmpty) {
              ReaderFushiSource.instance.toggleTapEmptyToHideChrome();
              await _pumpForPref(tester);
            }
            expect(ReaderFushiSource.instance.tapEmptyToHideChrome, isFalse,
                reason: 'B needs squeeze mode (tap_empty_hide_chrome=false)');

            final String audiobookKey = await seedAudiobook(tester,
                title: 'BUG-2467 Squeeze Audiobook');
            await _openSeededBook(tester, audiobookKey);

            AudiobookPlayerController? ctrl;
            await _waitFor(tester, () {
              ctrl = appModel.audiobookSession.controller;
              return ctrl != null && ctrl!.chapterCueCount > 0;
            }, 'audiobook controller attached', maxPolls: 80);
            debugPrint('[inset-probe] B cueCount=${ctrl!.chapterCueCount}');

            await _waitFor(
                tester,
                () => find.byKey(_kPlayBarKey).evaluate().isNotEmpty,
                'audiobook play bar (squeeze mode)',
                maxPolls: 60);
            await tester.pump(const Duration(seconds: 1));
            final _RunJs? runJsB = ReaderFushiPage.debugEvaluateJavascript;
            expect(runJsB, isNotNull);
            final _InsetProbe squeeze = await _settledProbe(
                tester, runJsB!, 'B squeeze (bar occupies)');
            await _capture(tester, 'observe-b1-squeeze-play-bar');

            final int playBars = find.byKey(_kPlayBarKey).evaluate().length;
            final int barProgress =
                find.byKey(_kBarProgressKey).evaluate().length;
            final int footers = find.byKey(_kStatusFooterKey).evaluate().length;
            final int footerProgress =
                find.byKey(_kFooterProgressKey).evaluate().length;
            debugPrint('[inset-probe] B squeeze: playBar=$playBars '
                'barProgress=$barProgress statusFooter=$footers '
                'footerProgress=$footerProgress bottomInset=${_f(squeeze.bottomInset)}');
            expect(playBars, 1, reason: 'squeeze mode must show the play bar');
            expect(barProgress, 1,
                reason:
                    'wide window: the readout is inlined at the bar\'s right '
                    'end (precondition for absorption)');
            expect(footers, 0,
                reason: 'BUG-2467: with the readout inlined into the occupying '
                    'bar, the status footer must not paint a second copy');
            expect(footerProgress, 0,
                reason: 'BUG-2467: only ONE progress readout may be on screen');
            expect(squeeze.bottomInset, greaterThan(30),
                reason: 'squeeze bar must occupy layout (bottom inset ≈ bar '
                    'height, no extra footer row)');

            // 切回悬浮态（2026-09-13 语义）：底栏 / 状态行都不占位、随控制栏一起
            // 收起，正文满屏；屏底只剩一条 2px 细进度线当读数。
            ReaderFushiSource.instance.toggleTapEmptyToHideChrome();
            await _pumpForPref(tester);
            expect(ReaderFushiSource.instance.tapEmptyToHideChrome, isTrue);
            ReaderFushiSource.onChromeReanchorLive?.call();
            await _waitFor(
                tester,
                () => find.byKey(_kEdgeLineKey).evaluate().isNotEmpty,
                'progress edge line (floating mode, chrome hidden)',
                maxPolls: 40);
            final _InsetProbe floating =
                await _settledProbe(tester, runJsB, 'B floating (bar hidden)');
            await _capture(tester, 'observe-b2-floating-status-footer');
            final int footersFloating =
                find.byKey(_kStatusFooterKey).evaluate().length;
            final int footerProgressFloating =
                find.byKey(_kFooterProgressKey).evaluate().length;
            final int playBarsFloating =
                find.byKey(_kPlayBarKey).evaluate().length;
            final int edgeLines = find.byKey(_kEdgeLineKey).evaluate().length;
            debugPrint('[inset-probe] B floating: playBar=$playBarsFloating '
                'statusFooter=$footersFloating '
                'footerProgress=$footerProgressFloating edgeLine=$edgeLines '
                'bottomInset=${_f(floating.bottomInset)}');
            expect(footersFloating, 0,
                reason: 'floating mode (chrome hidden): the status footer hides '
                    'with the rest of the chrome — body goes full-bleed');
            expect(footerProgressFloating, 0);
            expect(edgeLines, 1,
                reason: 'floating mode: the 2px edge line is the only readout '
                    'left while the chrome is hidden');
            expect(floating.bottomInset, lessThan(squeeze.bottomInset - 20),
                reason: 'floating chrome no longer occupies layout: bottom '
                    'inset drops to the system inset');
            debugPrint('[inset-probe] B PASS: squeeze → footer absorbed '
                '(1 readout); floating → chrome hidden, edge line only');
          } finally {
            if (ReaderFushiSource.instance.tapEmptyToHideChrome !=
                originalTapEmpty) {
              ReaderFushiSource.instance.toggleTapEmptyToHideChrome();
              await _pumpForPref(tester);
            }
            await _closeReader(tester);
          }
        },
      );
    },
  );
}

String _f(dynamic v) {
  if (v is num) return v.toStringAsFixed(2);
  return v.toString();
}
