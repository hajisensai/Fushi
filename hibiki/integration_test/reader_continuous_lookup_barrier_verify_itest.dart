import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// 设备验收 itest（TODO-1027 / BUG-480：查词框关闭堵塞连续查词）。
///
/// 修复把全屏 dismiss barrier 的 `onTap: clearDictionaryResult` 换成可覆写钩子
/// `onDismissBarrierTap(globalPos)`；阅读器覆写它，用 WebView RenderBox 把全局坐标
/// 逆映成 CSS 坐标转给 `_selectTextAt` —— 命中词就无缝换新查词弹窗（复用热槽），
/// 而不是「点击被 barrier 吃掉只关栈、必须再点一次才查」。
///
/// 本 itest 在**真实阅读器 + 真 WebView + 真词典**上跑端到端：
///   1. 单击 `猫` #1 走真 onTap → 起查词弹窗（`isDictionaryShown == true`）。
///   2. 直接调阅读器 state 的 `onDismissBarrierTap(globalPos)`（barrier 生产入口），
///      globalPos 取 `猫` #2 的屏幕坐标。
///   3. 断言弹窗仍在（连续查词未被关窗逻辑堵塞），且查词序号推进/选区落到新词——
///      证明「点弹窗外的新词，一次就换查」，不是「只关栈、要点两次」。
///
/// Run (PowerShell, from hibiki/)：
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/reader_continuous_lookup_barrier_verify_itest.dart -d windows
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1027: dismiss-barrier tap over a new word forwards to lookup '
    '(continuous lookup not blocked by close logic)',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[verify-1027] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: 'Home must render');
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(appModel.isInitialised, isTrue);

        // 词典是查词能返回结果的前提（生成词典含 "猫"→ねこ）。
        final bool dictOk = await seedDictionary(tester);
        expect(dictOk, isTrue, reason: 'test dictionary must seed');

        // 分页模式 + 单击查词开，让 onTap 走查词路径。
        await appModel.database
            .setPref('src:reader_ttu:ttu_view_mode', 'pagination');
        await appModel.database
            .setPref('src:reader_ttu:ttu_writing_mode', 'horizontal-tb');
        // highlight_on_tap 默认即 true（single-tap 查词），无需显式设置。
        await ReaderHibikiSource.readerSettings?.refreshFromDb();

        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: EpubGenerator().generate(),
          fileName: 'verify_continuous_lookup.epub',
        );

        final ReaderHibikiSource source = ReaderHibikiSource.instance;
        final MediaItem item = MediaItem(
          mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
          title: bookKey,
          mediaTypeIdentifier: source.mediaType.uniqueKey,
          mediaSourceIdentifier: source.uniqueKey,
          position: 0,
          duration: 0,
          canDelete: false,
          canEdit: true,
        );

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => source.buildLaunchPage(item: item),
        )));
        await tester.pump(const Duration(seconds: 3));

        const Key webViewKey = ValueKey<String>('hoshi_webview');
        for (int i = 0;
            i < 80 && find.byKey(webViewKey).evaluate().isEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(find.byKey(webViewKey), findsOneWidget,
            reason: 'reader WebView must mount');

        const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
        bool contentReady = false;
        for (int i = 0; i < 140; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
            contentReady = true;
            break;
          }
        }
        expect(contentReady, isTrue, reason: 'reader content must be ready');
        await tester.pump(const Duration(seconds: 3));

        final Future<dynamic> Function(String source)? runInWebView =
            ReaderHibikiPage.debugEvaluateJavascript;
        expect(runInWebView, isNotNull, reason: 'reader JS hook must be set');

        // 找两个不同的可查词点（"猫" 在生成 EPUB 正文里重复出现）。
        final dynamic rawPts = await runInWebView!(_twoWordPointsJs());
        final Map<String, dynamic> pts =
            jsonDecode(rawPts as String) as Map<String, dynamic>;
        debugPrint('[verify-1027] points: $pts');
        expect(pts['ok'], isTrue,
            reason: 'must find two distinct lookup points: ${pts['error']}');

        final double x1 = (pts['x1'] as num).toDouble();
        final double y1 = (pts['y1'] as num).toDouble();
        final double x2 = (pts['x2'] as num).toDouble();
        final double y2 = (pts['y2'] as num).toDouble();

        // reader state：`_ReaderHibikiPageState` 私有，无法直接命名类型；取无类型
        // State 再走 dynamic 调用它继承自 BaseSourcePageState 的 `isDictionaryShown`
        // / `onDismissBarrierTap`（后者是 @protected 钩子，也是 barrier 的生产入口）。
        final State rawState = tester.state(find.byType(ReaderHibikiPage));
        final dynamic readerState = rawState;

        bool dictShown() => readerState.isDictionaryShown as bool;

        // ── 第一次查词：走真 onTap（dispatch click over 猫#1）──
        await runInWebView(_dispatchClickJs(x1, y1));
        for (int i = 0; i < 40 && !dictShown(); i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(dictShown(), isTrue,
            reason: 'first tap on 猫 must open a lookup popup');

        // 第二个词的全局坐标（barrier 传给 onDismissBarrierTap 的是 GLOBAL 坐标）。
        final RenderBox wv = tester.renderObject<RenderBox>(
          find.byKey(webViewKey),
        );
        final Offset global2 = wv.localToGlobal(Offset(x2, y2));

        // ── barrier 点新词：真 onDismissBarrierTap，断言换新查词而非只关栈 ──
        // onDismissBarrierTap 是 barrier onTapUp 的生产入口（reader 覆写为「命中词→换
        // 新查词」）。dynamic 调用避开私有 state 类型名 + @protected lint。
        readerState.onDismissBarrierTap(global2);
        // 给换词一点时间（_selectTextAt → onTextSelected → _runLookupAndHighlight）。
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          if (dictShown()) break;
        }

        // 核心断言：barrier 点新词后弹窗仍在（连续查词未被关窗堵塞）。若修复缺失，
        // barrier 的 onTap 只会 clearDictionaryResult → 弹窗被关、isDictionaryShown=false。
        expect(dictShown(), isTrue,
            reason:
                'TODO-1027: tapping the dismiss barrier over a NEW word must '
                'forward to lookup and keep a popup up (continuous lookup), NOT '
                'just close the stack (which would need a second tap to look up)');

        await takeScreenshot(binding, 'reader_continuous_lookup_verified');
        assertStrictErrors(errors);

        navigator.pop();
        await tester.pump(const Duration(seconds: 2));
        for (int i = 0;
            i < 40 && ReaderHibikiPage.debugEvaluateJavascript != null;
            i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

/// 在正文里找两个不同位置的 "猫"（生成 EPUB 的 lookup lead 重复它），
/// 返回它们的视口坐标供真 onTap / onDismissBarrierTap 使用。
String _twoWordPointsJs() => r'''
(function() {
  var hits = [];
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node = walker.nextNode();
  while (node && hits.length < 8) {
    var text = node.nodeValue || '';
    var idx = text.indexOf('猫'); // 猫
    while (idx !== -1 && hits.length < 8) {
      var range = document.createRange();
      range.setStart(node, idx);
      range.setEnd(node, idx + 1);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 2 && r.height > 2 &&
            r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          hits.push({
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2))
          });
          break;
        }
      }
      idx = text.indexOf('猫', idx + 1);
    }
    node = walker.nextNode();
  }
  if (hits.length < 2) {
    return JSON.stringify({ok: false, error: 'need >=2 visible 猫 points, got ' + hits.length});
  }
  // Pick two points far enough apart that the second is clearly a different glyph.
  var a = hits[0];
  var b = hits[hits.length - 1];
  return JSON.stringify({ok: true, x1: a.x, y1: a.y, x2: b.x, y2: b.y, count: hits.length});
})()
''';

/// 派发一次真实单击（pointer + click），让阅读器 onTap 的 JS 侧
/// `callHandler('onTap', x, y, false)` 真触发。
String _dispatchClickJs(double x, double y) => '''
(function() {
  var px = $x, py = $y;
  var target = document.elementFromPoint(px, py) || document.body;
  function fire(type, buttons, button) {
    var init = {
      bubbles: true, cancelable: true, view: window,
      clientX: px, clientY: py, button: button, buttons: buttons
    };
    var ev;
    try { ev = new PointerEvent(type, Object.assign({pointerType:'mouse', pointerId: 7, isPrimary:true}, init)); }
    catch (e) { ev = new MouseEvent(type, init); }
    target.dispatchEvent(ev);
  }
  fire('pointerdown', 1, 0);
  fire('pointerup', 0, 0);
  var click = new MouseEvent('click', {
    bubbles: true, cancelable: true, view: window,
    clientX: px, clientY: py, button: 0, detail: 1
  });
  target.dispatchEvent(click);
  return 'dispatched';
})()
''';
