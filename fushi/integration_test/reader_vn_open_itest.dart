import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema.dart';

import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedAudiobook,
        seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// VN（视觉小说）阅读模式真 app 证据（Windows 离屏 runner，真 WebView + 真引擎）。
///
/// 五条用户路径，每条都探 JS 侧（`window.fushiReader` / VN stage / 屏数 / cloak）
/// 并抓 WebView 真像素：
///   A. 竖排 `vertical-rl` + `view_mode='vn'` 冷开书；用**键盘 PageDown**（走 Dart
///      `_paginate` → 进度刷新 → 位置落库）翻 5 屏；
///   B. 关书重开 → charOffset 恢复锚必须落回翻到的那一屏（不是屏 0）；
///   C. 分页模式开着书，切到 VN（设置页同一条链：`setReaderViewMode` +
///      `onLayoutReloadLive`），章节重载后再次 content-ready 并渲染 stage；
///   D. 有声书（带 cue）在 VN 下开书：stage 在、cue 已灌进引擎；
///   E. 阅读设置页：view_mode=vn 时「视觉小说」设置组与其开关在树里；切回分页后消失。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_vn_open_itest.dart

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
      debugPrint('[vn-open] $label ready after ${i * step.inMilliseconds}ms');
      return true;
    }
  }
  debugPrint(
    '[vn-open] $label NOT ready within ${maxPolls * step.inMilliseconds}ms',
  );
  return false;
}

const String _probeJs = r'''
(function () {
  var r = window.fushiReader;
  var C = window.__fushiReaderConfig || {};
  var stage = document.querySelector('.fushi-vn-stage');
  var cloak = document.getElementById('fushi-cloak');
  var bodyCs = getComputedStyle(document.body);
  var out = {
    hasReader: !!r,
    cfgVnMode: C.vnMode,
    nav: C.navigationGeneration,
    initialCharOffset: C.initialCharOffset,
    writingMode: bodyCs.writingMode,
    stage: !!stage,
    stageText: stage ? (stage.textContent || '').slice(0, 60) : null,
    stageRect: stage ? (function(b){return [b.x,b.y,b.width,b.height];})(stage.getBoundingClientRect()) : null,
    screens: r && r.screens ? r.screens.length : null,
    idx: r ? r.currentScreenIndex : null,
    firstChar: (r && typeof r.getFirstVisibleCharOffset === 'function') ? r.getFirstVisibleCharOffset() : null,
    cues: r && r.sentenceAudioCues ? r.sentenceAudioCues.length : null,
    cueWrappers: r && r.cueWrappers ? r.cueWrappers.size : null,
    cloak: !!cloak,
    bodyVisibility: bodyCs.visibility,
    bodyText: (document.body.innerText || '').slice(0, 60),
    progress: (r && typeof r.calculateProgress === 'function') ? r.calculateProgress() : null
  };
  return JSON.stringify(out);
})()
''';

typedef _RunJs = Future<dynamic> Function(String source);

Future<Map<String, dynamic>> _probe(_RunJs runJs) async {
  final Object? raw = await runJs(_probeJs);
  return raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final ObserveShot frame = await captureFlutterFrame(tester, name);
  debugPrint(
    '[vn-open] frame $name saved=${frame.saved} '
    'nonBlank=${frame.nonBlank} path=${frame.path}',
  );
  if (!_readerPageGone()) {
    final ObserveShot web = await captureReaderWebView('$name-webview');
    debugPrint(
      '[vn-open] webview $name saved=${web.saved} '
      'nonBlank=${web.nonBlank} path=${web.path}',
    );
  }
}

Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 开书并等 WebView / content-ready / debug 钩子；返回 content 是否就绪。
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
  await tester.pump(const Duration(seconds: 2));
  debugPrint(
    '[vn-open] $label webView=$webView content=$content hooks=$hooks '
    'readerPage=${find.byType(ReaderFushiPage).evaluate().length}',
  );
  return webView && content;
}

Future<Map<String, dynamic>?> _probeAndLog(String label) async {
  final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
  if (runJs == null) {
    debugPrint('[vn-open] $label: no JS hook; cannot probe engine');
    return null;
  }
  final Map<String, dynamic> m = await _probe(runJs);
  debugPrint('[vn-open] $label ${jsonEncode(m)}');
  return m;
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

/// 推真实的「阅读」设置详情页（与 comprehensive_settings_test 同一做法）。
Future<void> _openReadingSettingsPage(WidgetTester tester) async {
  final NavigatorState nav = Navigator.of(
    tester.element(find.byType(Scaffold).first),
  );
  unawaited(
    nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext routeCtx) => Consumer(
          builder: (BuildContext ctx, WidgetRef ref, _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            final SettingsDestination reading =
                buildSettingsSchema(sctx).firstWhere(
              (SettingsDestination d) => d.id == SettingsDestinationId.reading,
            );
            return SettingsDetailPage(destination: reading);
          },
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeSettingsPage(WidgetTester tester) async {
  final Finder detailPage = find.byType(SettingsDetailPage);
  if (detailPage.evaluate().isNotEmpty) {
    Navigator.of(tester.element(detailPage.first)).pop();
    await tester.pump(const Duration(milliseconds: 800));
  }
}

/// 标题可能带读数后缀（如「文字渐显速度 (45/s)」）且可能经 RichText 渲染，
/// 按包含匹配、把 RichText 算进来、不跳过 offstage（桌面两栏壳里推的路由
/// 可能被 finder 默认的 skipOffstage 漏掉）。
int _countVisibleTexts(List<String> labels) {
  int n = 0;
  for (final String label in labels) {
    final Finder f = find.textContaining(
      label,
      findRichText: true,
      skipOffstage: false,
    );
    final bool hit = f.evaluate().isNotEmpty;
    debugPrint('[vn-open] E label "$label" hit=$hit');
    if (hit) n++;
  }
  return n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'VN view mode: cold open (vertical) / keyboard turns persist / reopen '
    'restores / live switch / audiobook cues / VN settings section',
    timeout: const Timeout(Duration(minutes: 18)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'vn-open',
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
          try {
            // ── A. 竖排 + VN 冷开书，键盘翻 5 屏 ─────────────────────────
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderViewMode('vn');
            await _pumpForPref(tester);
            debugPrint(
              '[vn-open] prefs view_mode=${source.readerViewMode} '
              'writing_mode=${source.readerWritingMode}',
            );
            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'vn_open_probe.epub',
            );
            final bool aReady = await _openAndWait(tester, bookKey, 'A cold');
            await _capture(tester, 'vn-A1-cold-open');
            final Map<String, dynamic>? a1 = await _probeAndLog('A probe#1');
            if (!aReady) failures.add('A: content never ready');
            if (a1 != null && a1['stage'] != true) {
              failures.add('A: no VN stage after cold open');
            }
            for (int i = 0; i < 5; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
              await tester.pump(const Duration(milliseconds: 500));
            }
            // 让 500ms 去抖的位置落库跑完。
            await tester.pump(const Duration(seconds: 3));
            final Map<String, dynamic>? a2 = await _probeAndLog(
              'A probe#2 (after 5 PageDown)',
            );
            await _capture(tester, 'vn-A2-forward5');
            final int aIdx = (a2?['idx'] as num?)?.toInt() ?? -1;
            if (aIdx <= 0) {
              failures.add('A: keyboard PageDown did not advance VN screen');
            }

            // ── B. 关书重开：charOffset 恢复锚 ───────────────────────────
            await _closeReader(tester);
            final bool bReady = await _openAndWait(tester, bookKey, 'B reopen');
            await _capture(tester, 'vn-B1-reopen');
            final Map<String, dynamic>? b1 = await _probeAndLog('B probe#1');
            if (!bReady) failures.add('B: content never ready on reopen');
            if (b1 != null && b1['stage'] != true) {
              failures.add('B: no VN stage after reopen');
            }
            final int bIdx = (b1?['idx'] as num?)?.toInt() ?? -1;
            if (aIdx > 0 && bIdx <= 0) {
              failures.add(
                'B: reopen landed on screen $bIdx (was $aIdx before close)',
              );
            }

            // ── C. 分页模式开着书 → 切到 VN（设置页同一条链）────────────
            await _closeReader(tester);
            await source.setReaderViewMode('paginated');
            await _pumpForPref(tester);
            final bool cReady0 = await _openAndWait(
              tester,
              bookKey,
              'C paginated',
            );
            final Map<String, dynamic>? c0 = await _probeAndLog('C probe#0');
            if (!cReady0) failures.add('C: paginated open never ready');
            final int nav0 = (c0?['nav'] as num?)?.toInt() ?? -1;
            await source.setReaderViewMode('vn');
            ReaderFushiSource.onLayoutReloadLive?.call();
            await _pumpForPref(tester);
            bool switched = false;
            for (int i = 0; i < 60; i++) {
              await tester.pump(const Duration(milliseconds: 500));
              if (!_contentReady()) continue;
              final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
              if (runJs == null) continue;
              final Map<String, dynamic> m = await _probe(runJs);
              final int nav = (m['nav'] as num?)?.toInt() ?? -1;
              if (nav != nav0 && m['stage'] == true && m['cloak'] != true) {
                switched = true;
                debugPrint('[vn-open] C switched after ${i * 500}ms');
                break;
              }
            }
            await tester.pump(const Duration(seconds: 2));
            await _capture(tester, 'vn-C1-live-switch');
            final Map<String, dynamic>? c1 = await _probeAndLog('C probe#1');
            if (!switched) failures.add('C: live switch to VN never rendered');
            if (c1 != null && c1['stage'] != true) {
              failures.add('C: no VN stage after live switch');
            }
            await _closeReader(tester);

            // ── D. 有声书（带 cue）在 VN 下开书 ───────────────────────────
            final String audioKey = await seedAudiobook(tester);
            final bool dReady = await _openAndWait(
              tester,
              audioKey,
              'D audiobook',
            );
            await _capture(tester, 'vn-D1-audiobook');
            final Map<String, dynamic>? d1 = await _probeAndLog('D probe#1');
            if (!dReady) failures.add('D: audiobook content never ready');
            if (d1 != null && d1['stage'] != true) {
              failures.add('D: no VN stage for audiobook');
            }
            await _closeReader(tester);

            // ── E. 阅读设置页：VN 设置组随 view_mode 出现 / 消失 ──────────
            final List<String> vnLabels = <String>[
              t.reader_vn_settings,
              t.reader_vn_reveal_speed,
              t.reader_vn_screen_mode,
              t.reader_vn_click_advance,
              t.reader_vn_merge_spoken_sentence,
            ];
            await _openReadingSettingsPage(tester);
            final int shownVn = _countVisibleTexts(vnLabels);
            await _capture(tester, 'vn-E1-settings-vn');
            debugPrint('[vn-open] E view_mode=vn visible VN labels=$shownVn/5');
            if (shownVn == 0) {
              failures.add('E: VN settings section absent while view_mode=vn');
            }
            await _closeSettingsPage(tester);
            await source.setReaderViewMode('paginated');
            await _pumpForPref(tester);
            await _openReadingSettingsPage(tester);
            final int shownPaged = _countVisibleTexts(vnLabels);
            await _capture(tester, 'vn-E2-settings-paginated');
            debugPrint(
              '[vn-open] E view_mode=paginated visible VN labels=$shownPaged/5',
            );
            if (shownPaged != 0) {
              failures
                  .add('E: VN settings still shown while view_mode=paginated');
            }
            await _closeSettingsPage(tester);

            debugPrint('[vn-open] failures=${jsonEncode(failures)}');
            expect(failures, isEmpty, reason: failures.join('; '));
          } finally {
            await _closeReader(tester);
            await source.setReaderViewMode(baseViewMode);
            await source.setReaderWritingMode(baseWritingMode);
          }
        },
      );
    },
  );
}
