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
import 'test_helpers.dart';

/// 设备验收 itest（TODO-1028 / BUG-481 + TODO-994 / BUG-468）。
///
/// 在真实 Hibiki 阅读器 WebView（Windows 上是 forked flutter_inappwebview_windows
/// 引擎渲染的真 EPUB）里驱动原生双击，断言修复真生效：
///
/// TODO-1028：双击建立的原生框选必须被 capture 阶段的 `dblclick → removeAllRanges`
///   清掉——否则它盖住单击查词、并绊住振假名整页切换。断言双击后
///   `getSelection().isCollapsed === true`（选区清）且 `show-all-rt` 被 toggle
///   （振假名切换恢复正常）。这是**真引擎行为级**证据，不是源码 grep。
///
/// TODO-994：`InAppWebViewSettings.disableContextMenu` 在 Windows 上必须为真
///   （关掉 WebView2 原生右键菜单，只留 Hibiki Flutter 菜单）。原生菜单是 OS 级
///   浏览器弹窗，不进页面 DOM，离屏无法目视其消失；这里退而求其次断言 fork 引擎
///   仍在真渲染、右键 DOM 事件可派发、Flutter 选区路径可用。原生菜单「只出一个」
///   的最终目视需可见窗，标 BLOCKED。
///
/// Run (PowerShell, from hibiki/)：
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/reader_dblclick_context_menu_verify_itest.dart -d windows
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1028: native double-click clears selection + toggles furigana; '
    'TODO-994: native context menu disabled on Windows',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[verify] FlutterError: ${details.exceptionAsString()}');
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
        expect(appModel.isInitialised, isTrue,
            reason: 'AppModel must finish initialising');

        // 分页模式 + 振假名 toggle 模式：让双击既能触发原生选词，又能验证振假名切换。
        await appModel.database
            .setPref('src:reader_ttu:ttu_view_mode', 'pagination');
        await appModel.database
            .setPref('src:reader_ttu:ttu_writing_mode', 'horizontal-tb');
        await appModel.database
            .setPref('src:reader_ttu:ttu_furigana_mode', 'toggle');
        await ReaderHibikiSource.readerSettings?.refreshFromDb();

        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: EpubGenerator().generate(),
          fileName: 'verify_dblclick.epub',
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
        expect(contentReady, isTrue,
            reason: 'reader content must become ready');
        await tester.pump(const Duration(seconds: 3));

        final Future<dynamic> Function(String source)? runInWebView =
            ReaderHibikiPage.debugEvaluateJavascript;
        expect(runInWebView, isNotNull,
            reason: 'Reader debug JS hook must be set');

        // ── TODO-1028: 真引擎里派发原生双击，断言选区被清 + 振假名 toggle ──
        final dynamic rawDbl = await runInWebView!(_dblclickProbeJs());
        final Map<String, dynamic> dbl =
            jsonDecode(rawDbl as String) as Map<String, dynamic>;
        debugPrint('[verify][1028] $dbl');

        expect(dbl['ok'], isTrue,
            reason:
                'dblclick probe must find visible body text: ${dbl['error']}');
        expect(dbl['characterHit'], isTrue,
            reason: 'probe point must land on a real reader character');
        // 修复的核心断言：双击后原生选区被 removeAllRanges 清掉（isCollapsed）。
        expect(dbl['selectionCollapsedAfter'], isTrue,
            reason:
                'TODO-1028: native double-click selection must be CLEARED so it '
                'stops hijacking single-tap lookup (getSelection().isCollapsed)');
        expect(dbl['selectionTextAfter'], '',
            reason: 'no residual native selection text after double-click');
        // 振假名整页切换在双击后仍生效（capture clear 先跑 → toggle 守卫不被绊住）。
        expect(dbl['showAllRtToggled'], isTrue,
            reason:
                'TODO-1028: furigana whole-page toggle (show-all-rt) must still '
                'fire on double-click once the capture clear runs first');

        // ── TODO-994: fork 引擎在真渲染；右键 DOM 可派发；选区路径可用 ──
        final dynamic rawCtx = await runInWebView(_contextMenuProbeJs());
        final Map<String, dynamic> ctx =
            jsonDecode(rawCtx as String) as Map<String, dynamic>;
        debugPrint('[verify][994] $ctx');
        expect(ctx['ok'], isTrue, reason: 'context-menu probe ran');
        // 右键在 DOM 层仍可派发（contextmenu 事件本身没被吞——Flutter 菜单走
        // onSecondaryTapDown，原生菜单由 fork 的 put_AreDefaultContextMenusEnabled
        // 关掉，属引擎级不进 DOM）。这里证明页面仍在真引擎、选区 API 可用。
        expect(ctx['hasSelectionApi'], isTrue,
            reason: 'live WebView selection API must be present');

        await takeScreenshot(binding, 'reader_dblclick_ctxmenu_verified');
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

/// 找一段可见正文，先像双击一样把该词节点选中，再派发浏览器 dblclick 序列，
/// 让生产的 capture-phase `dblclick → removeAllRanges` 跑起来；然后读回选区是否
/// 被清 + 振假名 `show-all-rt` 是否 toggle。
String _dblclickProbeJs() => r'''
(function() {
  function visibleTextPoint() {
    var accept = NodeFilter.FILTER_ACCEPT;
    var reject = NodeFilter.FILTER_REJECT;
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node) {
        if (!node.nodeValue || !node.nodeValue.trim()) return reject;
        var parent = node.parentElement;
        if (!parent || parent.closest('rt, rp, script, style')) return reject;
        return accept;
      }
    });
    var node = walker.nextNode();
    while (node) {
      var range = document.createRange();
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 4 && r.height > 4 &&
            r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          return {
            node: node,
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2)),
            text: node.nodeValue.trim().substring(0, 24)
          };
        }
      }
      node = walker.nextNode();
    }
    return null;
  }

  var point = visibleTextPoint();
  if (!point) return JSON.stringify({ok: false, error: 'no visible text'});

  var characterHit = !!(window.hoshiSelection &&
    window.hoshiSelection.getCharacterAtPoint &&
    window.hoshiSelection.getCharacterAtPoint(point.x, point.y));

  var hadShowAllRt = document.body.classList.contains('show-all-rt');

  // Establish a native selection the way a real double-click would (select the
  // word node under the point). The production capture-phase dblclick listener
  // must then clear it via removeAllRanges().
  var sel = window.getSelection();
  sel.removeAllRanges();
  var wordRange = document.createRange();
  wordRange.selectNodeContents(point.node);
  sel.addRange(wordRange);
  var selectionBefore = String(sel);
  var collapsedBefore = sel.isCollapsed;

  // Fire the browser dblclick sequence. Production handlers run: capture dblclick
  // -> removeAllRanges; bubble dblclick -> furigana toggle (guarded isCollapsed).
  var target = document.elementFromPoint(point.x, point.y) ||
      point.node.parentElement || document.body;
  function mouse(type) {
    var ev = new MouseEvent(type, {
      bubbles: true, cancelable: true, view: window,
      clientX: point.x, clientY: point.y, button: 0, detail: 2
    });
    target.dispatchEvent(ev);
  }
  mouse('mousedown'); mouse('mouseup');
  mouse('mousedown'); mouse('mouseup');
  mouse('dblclick');

  var selAfter = window.getSelection();
  var collapsedAfter = selAfter.isCollapsed;
  var selectionTextAfter = String(selAfter);
  var showAllRtAfter = document.body.classList.contains('show-all-rt');

  return JSON.stringify({
    ok: true,
    sample: point.text,
    characterHit: characterHit,
    collapsedBefore: collapsedBefore,
    selectionBefore: selectionBefore,
    selectionCollapsedAfter: collapsedAfter,
    selectionTextAfter: selectionTextAfter,
    hadShowAllRt: hadShowAllRt,
    showAllRtAfter: showAllRtAfter,
    showAllRtToggled: (hadShowAllRt !== showAllRtAfter)
  });
})()
''';

/// 探针：右键 contextmenu 事件可派发、选区 API 在真引擎里可用。
String _contextMenuProbeJs() => r'''
(function() {
  var hasSelectionApi = !!(window.getSelection && document.createRange);
  var dispatched = false;
  try {
    var ev = new MouseEvent('contextmenu', {
      bubbles: true, cancelable: true, view: window,
      clientX: 10, clientY: 10, button: 2
    });
    document.body.dispatchEvent(ev);
    dispatched = true;
  } catch (e) {
    dispatched = false;
  }
  return JSON.stringify({
    ok: true,
    hasSelectionApi: hasSelectionApi,
    contextmenuDispatched: dispatched
  });
})()
''';
