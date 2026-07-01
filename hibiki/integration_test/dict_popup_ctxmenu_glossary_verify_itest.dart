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

/// 设备验收 itest（TODO-1018 / BUG-477 + TODO-1022 / BUG-478）。
///
/// 在真实 Hibiki 阅读器上打开一个真词典查词弹窗（Windows 上是 forked
/// flutter_inappwebview_windows 引擎渲染的独立第二个 WebView），对该弹窗
/// WebView 文档做 DOM-rect / computed-style 探针，断言两个修复在真引擎里生效。
///
/// TODO-1018：弹窗 WebView 的 InAppWebViewSettings.disableContextMenu 在 Windows
///   上为真（压掉 WebView2 原生右键菜单，此前查词弹窗右键出两个菜单）。原生菜单是
///   OS 级弹窗不进 DOM，离屏无法目视其消失（同 TODO-994）；这里做行为级证据：弹窗
///   WebView 在真渲染、可对文档派发 contextmenu、JS 层不吞它（压制在原生侧）。原生
///   菜单「只出一个」的最终目视需可见窗，标 PARTIAL。
///
/// TODO-1022：structured-content 下带 gloss-sc-* 类的 span/div 携带词典 inline
///   float/position 时被 popup.css 中和回正常行内流（修引文/外字错位）。在真渲染的
///   弹窗文档里注入 gloss-sc-span/gloss-sc-div（各带 inline float:left;
///   position:relative），读回 getComputedStyle 断言 float=none / position=static；
///   注入 gloss-image-link 内 span 作反向对照，断言它不被误伤。真引擎 computed-style
///   + DOM-rect 证据，不是源码 grep。
///
/// Run (PowerShell, from hibiki/)：
///   flutter test integration_test/dict_popup_ctxmenu_glossary_verify_itest.dart -d windows
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1018: popup WebView native context menu disabled; '
    'TODO-1022: gloss-sc span/div float/position neutralized in live popup',
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
        expect(appModel.isInitialised, isTrue);

        final bool dictOk = await seedDictionary(tester);
        expect(dictOk, isTrue, reason: 'test dictionary must seed');

        await appModel.database
            .setPref('src:reader_ttu:ttu_view_mode', 'pagination');
        await appModel.database
            .setPref('src:reader_ttu:ttu_writing_mode', 'horizontal-tb');
        await ReaderHibikiSource.readerSettings?.refreshFromDb();

        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: EpubGenerator().generate(),
          fileName: 'verify_popup_ctxmenu_glossary.epub',
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

        final Future<dynamic> Function(String source)? runInReader =
            ReaderHibikiPage.debugEvaluateJavascript;
        expect(runInReader, isNotNull, reason: 'reader JS hook must be set');

        // ── 打开真词典查词弹窗：在正文 WebView 派发单击 "猫" 走真 onTap ──
        final dynamic rawPt = await runInReader!(_wordPointJs());
        final Map<String, dynamic> pt =
            jsonDecode(rawPt as String) as Map<String, dynamic>;
        debugPrint('[verify][1018/1022] word point: $pt');
        expect(pt['ok'], isTrue,
            reason: 'must find a visible lookup glyph: ${pt['error']}');
        final double x1 = (pt['x'] as num).toDouble();
        final double y1 = (pt['y'] as num).toDouble();

        final State rawState = tester.state(find.byType(ReaderHibikiPage));
        final dynamic readerState = rawState;
        bool dictShown() => readerState.isDictionaryShown as bool;

        await runInReader(_dispatchClickJs(x1, y1));
        for (int i = 0; i < 60 && !dictShown(); i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(dictShown(), isTrue,
            reason: 'tap on glyph must open a lookup popup WebView');

        // 弹窗 WebView 的 evaluateJavascript 钩子（顶层可见弹窗）。
        final Future<dynamic> Function(String source)? runInPopup =
            ReaderHibikiPage.debugEvaluateTopPopup;
        expect(runInPopup, isNotNull,
            reason: 'top-popup JS hook must be wired once a popup is up');

        // 等弹窗文档就绪。
        bool popupReady = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          final dynamic r = await runInPopup!(_popupReadyJs());
          if (r != null) {
            final Map<String, dynamic> rr =
                jsonDecode(r as String) as Map<String, dynamic>;
            if (rr['ready'] == true) {
              popupReady = true;
              break;
            }
          }
        }
        expect(popupReady, isTrue,
            reason: 'popup WebView document must become ready');

        // ── TODO-1022 探针：注入 gloss-sc span/div + image-link 反向对照 ──
        final dynamic rawGloss = await runInPopup!(_glossaryNeutralizeProbeJs());
        final Map<String, dynamic> gloss =
            jsonDecode(rawGloss as String) as Map<String, dynamic>;
        debugPrint('[verify][1022] glossary neutralize probe: $gloss');
        expect(gloss['ok'], isTrue,
            reason: 'glossary probe must run: ${gloss['error']}');

        expect(gloss['spanFloat'], 'none',
            reason:
                'TODO-1022: gloss-sc-span float must be neutralized to none, '
                'got ${gloss['spanFloat']}');
        expect(gloss['spanPosition'], 'static',
            reason: 'TODO-1022: gloss-sc-span position must be neutralized to '
                'static, got ${gloss['spanPosition']}');
        expect(gloss['divFloat'], 'none',
            reason: 'TODO-1022: gloss-sc-div float must be neutralized to none, '
                'got ${gloss['divFloat']}');
        expect(gloss['divPosition'], 'static',
            reason: 'TODO-1022: gloss-sc-div position must be neutralized to '
                'static, got ${gloss['divPosition']}');

        // DOM-rect：中和后的 span 落在正常行内流（垂直中心与父行锚点接近）。
        expect(gloss['spanInFlow'], isTrue,
            reason: 'TODO-1022: neutralized gloss-sc-span must sit in normal '
                'inline flow, span rect ${gloss['spanRect']} vs anchor '
                '${gloss['anchorRect']}');

        // 反向对照：gloss-image-link 内 span 不被中和（revert 保留 float/position）。
        expect(gloss['imgLinkSpanFloat'], isNot('none'),
            reason: 'TODO-1022: gloss-image-link span float must NOT be '
                'neutralized (revert preserved), got '
                '${gloss['imgLinkSpanFloat']}');

        // ── TODO-1018 探针：弹窗 WebView 可派发 contextmenu，JS 层不吞它 ──
        final dynamic rawCtx = await runInPopup(_contextMenuProbeJs());
        final Map<String, dynamic> ctx =
            jsonDecode(rawCtx as String) as Map<String, dynamic>;
        debugPrint('[verify][1018] popup contextmenu probe: $ctx');
        expect(ctx['ok'], isTrue,
            reason: 'popup contextmenu probe must run: ${ctx['error']}');
        expect(ctx['dispatched'], isTrue,
            reason: 'contextmenu event must dispatch on live popup document');
        expect(ctx['defaultPreventedByJs'], isFalse,
            reason: 'popup JS must NOT preventDefault contextmenu (native '
                'disableContextMenu is the sole suppressor per TODO-1018)');
        expect(dictShown(), isTrue,
            reason: 'popup WebView must survive contextmenu dispatch');

        await takeScreenshot(binding, 'dict_popup_ctxmenu_glossary_verified');
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

/// 在正文里找一个可见的查词字（生成词典含 "猫"），返回视口坐标供真 onTap 起查词。
String _wordPointJs() => r'''
(function() {
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node = walker.nextNode();
  while (node) {
    var text = node.nodeValue || '';
    var idx = text.indexOf('猫');
    while (idx !== -1) {
      var range = document.createRange();
      range.setStart(node, idx);
      range.setEnd(node, idx + 1);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 2 && r.height > 2 &&
            r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          return JSON.stringify({
            ok: true,
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2))
          });
        }
      }
      idx = text.indexOf('猫', idx + 1);
    }
    node = walker.nextNode();
  }
  return JSON.stringify({ok: false, error: 'no visible glyph found'});
})()
''';

/// 派发一次真实单击，让阅读器 onTap 的 callHandler('onTap', x, y, false) 触发。
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

/// 弹窗文档就绪探针。
String _popupReadyJs() => r'''
(function() {
  try {
    if (!document || !document.body) {
      return JSON.stringify({ready: false});
    }
    return JSON.stringify({ready: true});
  } catch (e) {
    return JSON.stringify({ready: false, error: String(e)});
  }
})()
''';

/// TODO-1022 探针：在真弹窗文档造 structured-content，放带 inline float/position 的
/// gloss-sc-span、gloss-sc-div，以及 gloss-image-link 内 gloss-sc-span 反向对照，
/// 读回 getComputedStyle + getBoundingClientRect。
String _glossaryNeutralizeProbeJs() => r'''
(function() {
  try {
    var host = document.createElement('span');
    host.className = 'structured-content';
    host.setAttribute('data-verify-1022', '1');
    var anchor = document.createElement('span');
    anchor.textContent = 'ANCHOR';
    host.appendChild(anchor);
    var scSpan = document.createElement('span');
    scSpan.className = 'gloss-sc-span';
    scSpan.style.cssText = 'float:left;position:relative;top:-40px;left:80px;';
    scSpan.textContent = 'Q';
    host.appendChild(scSpan);
    var scDiv = document.createElement('div');
    scDiv.className = 'gloss-sc-div';
    scDiv.style.cssText = 'float:left;position:relative;top:-40px;left:80px;';
    scDiv.textContent = 'DIV';
    host.appendChild(scDiv);
    var imgLink = document.createElement('a');
    imgLink.className = 'gloss-image-link';
    var imgSpan = document.createElement('span');
    imgSpan.className = 'gloss-sc-span';
    imgSpan.style.cssText = 'float:left;position:relative;';
    imgSpan.textContent = 'IMG';
    imgLink.appendChild(imgSpan);
    host.appendChild(imgLink);

    document.body.appendChild(host);
    void host.offsetHeight;

    var spanCs = window.getComputedStyle(scSpan);
    var divCs = window.getComputedStyle(scDiv);
    var imgSpanCs = window.getComputedStyle(imgSpan);

    var anchorRect = anchor.getBoundingClientRect();
    var spanRect = scSpan.getBoundingClientRect();
    var anchorMidY = anchorRect.top + anchorRect.height / 2;
    var spanMidY = spanRect.top + spanRect.height / 2;
    var spanInFlow = Math.abs(spanMidY - anchorMidY) < 30;

    var result = {
      ok: true,
      spanFloat: spanCs.getPropertyValue('float') || spanCs.cssFloat || '',
      spanPosition: spanCs.getPropertyValue('position'),
      divFloat: divCs.getPropertyValue('float') || divCs.cssFloat || '',
      divPosition: divCs.getPropertyValue('position'),
      imgLinkSpanFloat: imgSpanCs.getPropertyValue('float') || imgSpanCs.cssFloat || '',
      imgLinkSpanPosition: imgSpanCs.getPropertyValue('position'),
      anchorRect: {top: anchorRect.top, left: anchorRect.left, h: anchorRect.height},
      spanRect: {top: spanRect.top, left: spanRect.left, h: spanRect.height},
      spanInFlow: spanInFlow
    };
    host.remove();
    return JSON.stringify(result);
  } catch (e) {
    return JSON.stringify({ok: false, error: String(e)});
  }
})()
''';

/// TODO-1018 探针：在真弹窗文档派发 contextmenu，读回是否被 JS preventDefault。
String _contextMenuProbeJs() => r'''
(function() {
  try {
    var target = document.body;
    var ev;
    try {
      ev = new MouseEvent('contextmenu', {
        bubbles: true, cancelable: true, view: window,
        clientX: 8, clientY: 8, button: 2, buttons: 2
      });
    } catch (e) {
      return JSON.stringify({ok: false, error: 'MouseEvent ctor failed: ' + String(e)});
    }
    var dispatched = target.dispatchEvent(ev);
    return JSON.stringify({
      ok: true,
      dispatched: true,
      defaultPreventedByJs: !dispatched
    });
  } catch (e) {
    return JSON.stringify({ok: false, error: String(e)});
  }
})()
''';
