import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/pagination_test_harness.dart';
import 'test_helpers.dart';

/// BUG-007 端到端（真实分页阅读器）：在 *真实* CSS 多栏 + overflow:hidden +
/// scrollLeft 离散翻页的阅读器里，注入 *真实* 产品 bridge，模拟有声书 cue 推进
/// 跨过一张整页插图，验证两件 bare-WebView 测不到的事：
///   1. 命中插图时视口真的滚到插图、插图成为可见页（gap2 在真实分页下成立）。
///   2. 恢复后重新 reveal 当前 cue，插图后的正文显示出来（续播 audio-follow）。
/// 并记录翻页轴 scroll 相对列距 columnPitch 的对齐情况（信息性，reveal 是绝对
/// 定位、非累积，故不硬断言对齐）。
///
/// 不需要真实音频/cue 管线——本残留是「真实分页下 reveal 行为」问题，与音频无关；
/// 通过 `debugInjectAudiobookBridge` 注入真实 bridge，再用 `debugEvaluateJavascript`
/// 直接驱动 `__hoshiHighlight`（产品 reveal 路径）。
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/image_pause_realreader_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'BUG-007 e2e: real paginated reader reveals image on cross, text on resume',
      (WidgetTester tester) async {
    app.main();
    expect(await waitForHome(tester), isTrue, reason: 'Home must render');
    await tester.pump(const Duration(seconds: 2));

    final FocusDriver driver = FocusDriver(tester);

    // ── 打开（必要时自种）测试书 ──────────────────────────────────────────
    final List<Finder> nav = findPrimaryNavigationTargets();
    if (nav.isNotEmpty) {
      final bool focusedTab = await driver.focusWidget(nav.first);
      expect(focusedTab, isTrue,
          reason: 'Books tab must be reachable by focus');
      await driver.activate();
      await tester.pumpAndSettle();
    }
    Finder entries = findBookEntries();
    for (int i = 0; i < 20 && entries.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      entries = findBookEntries();
    }
    if (entries.evaluate().isEmpty) {
      await seedReaderBook(tester);
      if (nav.isNotEmpty) {
        final bool focusedTab = await driver.focusWidget(nav.first);
        expect(focusedTab, isTrue,
            reason: 'Books tab must be reachable by focus');
        await driver.activate();
        await tester.pumpAndSettle();
      }
      entries = findBookEntries();
      for (int i = 0; i < 20 && entries.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        entries = findBookEntries();
      }
    }
    expect(entries.evaluate(), isNotEmpty, reason: 'need a book on the shelf');

    final bool focusedBook = await driver.focusWidget(entries.first);
    expect(focusedBook, isTrue, reason: 'Book card must be reachable by focus');
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    const Key webViewKey = ValueKey<String>('hoshi_webview');
    for (int i = 0; i < 60 && find.byKey(webViewKey).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byKey(webViewKey), findsOneWidget, reason: 'WebView present');

    const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
    bool ready = false;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
        ready = true;
        break;
      }
    }
    expect(ready, isTrue, reason: 'reader content ready');
    await tester.pump(const Duration(seconds: 4));

    final Future<dynamic> Function(String)? runJs =
        ReaderHibikiPage.debugEvaluateJavascript;
    final Future<void> Function()? injectBridge =
        ReaderHibikiPage.debugInjectAudiobookBridge;
    expect(runJs, isNotNull, reason: 'debug JS hook set (debug build)');
    expect(injectBridge, isNotNull, reason: 'bridge inject hook set');

    // ── 注入真实 bridge + 整页大图(插在 m101 前) + 分页 harness ───────────
    await injectBridge!();
    await tester.pump(const Duration(milliseconds: 300));
    await runJs!(paginationHarnessJs);
    final dynamic setup = await runJs(_insertImageJs);
    debugPrint('[IMGPAUSE-E2E] setup=$setup');
    final Map<String, dynamic> setupMap =
        jsonDecode(setup as String) as Map<String, dynamic>;
    expect(setupMap['hasPic'], isTrue, reason: 'full-page image injected');
    expect(setupMap['hasHighlight'], isTrue,
        reason: 'real __hoshiHighlight injected by bridge');

    // ── 模拟 cue 推进：先 reveal 图片前一句 m100，再推进到图片后一句 m101 ──
    await runJs("window.__hoshiHighlight('#m100', true);");
    await tester.pump(const Duration(milliseconds: 600));
    final double m100Frac = await _frac(runJs, 'm100');
    final String alignAfterM100 = await _align(runJs);
    debugPrint(
        '[IMGPAUSE-E2E] after m100: m100Frac=$m100Frac align=$alignAfterM100');

    // 推进到 m101 —— 中间隔着整页插图 → 应 reveal 到插图(暂停时看得到图)。
    await runJs("window.__hoshiHighlight('#m101', true);");
    await tester.pump(const Duration(milliseconds: 600));
    final double picFrac = await _frac(runJs, 'rrPic');
    final double m101FracAtCross = await _frac(runJs, 'm101');
    final String alignAtCross = await _align(runJs);
    debugPrint('[IMGPAUSE-E2E] at cross: picFrac=$picFrac '
        'm101Frac=$m101FracAtCross align=$alignAtCross');

    // ── 模拟恢复：重新 reveal 当前 cue m101（插图后正文）应显示出来 ─────────
    await runJs("window.__hoshiHighlight('#m101', true);");
    await tester.pump(const Duration(milliseconds: 600));
    final double m101FracAfterResume = await _frac(runJs, 'm101');
    final double picFracAfterResume = await _frac(runJs, 'rrPic');
    final String alignAfterResume = await _align(runJs);
    debugPrint('[IMGPAUSE-E2E] after resume: m101Frac=$m101FracAfterResume '
        'picFrac=$picFracAfterResume align=$alignAfterResume');

    // ── 断言 ────────────────────────────────────────────────────────────
    debugPrint('[IMGPAUSE-E2E] ===== VERDICT =====');
    // gap2：跨过插图时插图成为可见页（暂停时看得到图）。
    expect(picFrac, greaterThanOrEqualTo(0.5),
        reason: '真实分页下 cue 跨过整页插图时，视口须滚到插图（暂停时图片可见），'
            '实测 picFrac=$picFrac');
    // 恢复：重新 reveal 当前 cue，插图后正文显示。
    expect(m101FracAfterResume, greaterThanOrEqualTo(0.5),
        reason: '恢复后重新 reveal 当前 cue（插图后那句 m101）须显示出来，'
            '实测 m101Frac=$m101FracAfterResume');
    debugPrint('[IMGPAUSE-E2E] gap2 image-visible-on-cross=$picFrac '
        'resume-text-visible=$m101FracAfterResume — PASS');
  });
}

// 整页大图(id=rrPic)插在 #m101 之前；data-URI 避开资源拦截。
const String _insertImageJs = r'''
(function(){
  try {
    if (!document.getElementById('rrPic')) {
      var wrap = document.createElement('div');
      wrap.id = 'rrWrap';
      wrap.style.cssText =
        'break-inside:avoid;-webkit-column-break-inside:avoid;' +
        'width:100%;height:88vh;display:block;';
      var img = document.createElement('img');
      img.id = 'rrPic';
      img.src = 'data:image/svg+xml;base64,' + btoa(
        '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="600">' +
        '<rect width="300" height="600" fill="#2980b9"/></svg>');
      img.style.cssText = 'display:block;width:100%;height:100%;object-fit:contain;';
      wrap.appendChild(img);
      var anchor = document.getElementById('m101') ||
                   document.querySelector('[id^="m"]');
      if (anchor && anchor.parentNode) {
        anchor.parentNode.insertBefore(wrap, anchor);
      } else {
        document.body.appendChild(wrap);
      }
    }
    if (window.hoshiReader && window.hoshiReader.buildPaginationMetrics) {
      try { window.hoshiReader.buildPaginationMetrics(); } catch (e) {}
    }
    return JSON.stringify({
      hasPic: !!document.getElementById('rrPic'),
      hasHighlight: typeof window.__hoshiHighlight === 'function'
    });
  } catch (e) {
    return JSON.stringify({err: '' + e});
  }
})();
''';

Future<double> _frac(Future<dynamic> Function(String) runJs, String id) async {
  final dynamic raw = await runJs(_fracJs(id));
  final Map<String, dynamic> m =
      jsonDecode(raw as String) as Map<String, dynamic>;
  return (m['frac'] as num?)?.toDouble() ?? 0;
}

String _fracJs(String id) => '''
(function(){
  var el = document.getElementById('$id');
  if (!el) return JSON.stringify({frac: 0});
  var rects = el.getClientRects();
  var ww = window.innerWidth, wh = window.innerHeight;
  var vis = 0, tot = 0;
  for (var r = 0; r < rects.length; r++) {
    var rc = rects[r];
    if (rc.width <= 0 || rc.height <= 0) continue;
    tot += rc.width * rc.height;
    var ix = Math.max(0, Math.min(rc.right, ww) - Math.max(rc.left, 0));
    var iy = Math.max(0, Math.min(rc.bottom, wh) - Math.max(rc.top, 0));
    vis += ix * iy;
  }
  return JSON.stringify({frac: tot > 0 ? Math.round(vis / tot * 100) / 100 : 0});
})();
''';

// scroll 相对 columnPitch 的对齐（信息性）。
Future<String> _align(Future<dynamic> Function(String) runJs) async {
  try {
    final dynamic raw =
        await runJs('window.hoshiTestHarness.getPaginationState();');
    final Map<String, dynamic> s =
        jsonDecode(raw as String) as Map<String, dynamic>;
    final int scroll = (s['scroll'] as num?)?.toInt() ?? 0;
    final int pitch = (s['columnPitch'] as num?)?.toInt() ?? 0;
    final int rem = pitch > 0 ? scroll % pitch : -1;
    return 'scroll=$scroll pitch=$pitch rem=$rem';
  } catch (e) {
    return 'align-error: $e';
  }
}
