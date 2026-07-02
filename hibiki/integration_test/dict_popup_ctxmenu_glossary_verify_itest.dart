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
/// TODO-1022 / BUG-478 / BUG-520：词典 structured-content 自带的 inline
///   float / position:absolute|fixed|sticky 现在在源头（popup.js
///   setStructuredContentElementStyle 里的 isFlowEscapingStructuredContentStyle）
///   被过滤，而不是 BUG-478 那条一刀切 CSS——那条规则的 display:inline 把所有
///   词典靠 div block 布局做的分行压成一行（BUG-520）。探针改为在真弹窗文档里
///   调用真实渲染管线 renderStructuredContent：
///   - 带 float/position:absolute|fixed 的 span/div 渲染后 computed float=none /
///     position=static（源头过滤生效）；
///   - div 渲染后 computed display=block，且两个 div 垂直堆叠（分行不变量，
///     BUG-520 的像素级证据）；
///   - position:relative 微调保留（computed position=relative）；
///   - 裸 gloss-sc-div（带 inline float，不经渲染管线）float 原样保留——证明
///     一刀切 CSS 已删、中和只发生在 JS 源头；
///   - .gloss-image-link 仍由 popup.css 拿到 position:relative（图片布局零回归）。
///   真引擎 computed-style + DOM-rect 证据，不是源码 grep。
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
        final dynamic rawGloss =
            await runInPopup!(_glossaryNeutralizeProbeJs());
        final Map<String, dynamic> gloss =
            jsonDecode(rawGloss as String) as Map<String, dynamic>;
        debugPrint('[verify][1022] glossary neutralize probe: $gloss');
        expect(gloss['ok'], isTrue,
            reason: 'glossary probe must run: ${gloss['error']}');

        expect(gloss['spanFloat'], 'none',
            reason: 'TODO-1022: dict float on rendered gloss-sc-span must be '
                'filtered at the source, got ${gloss['spanFloat']}');
        expect(gloss['spanPosition'], 'static',
            reason: 'TODO-1022: dict position:absolute on rendered '
                'gloss-sc-span must be filtered, got ${gloss['spanPosition']}');
        expect(gloss['divFloat'], 'none',
            reason: 'TODO-1022: dict float on rendered gloss-sc-div must be '
                'filtered at the source, got ${gloss['divFloat']}');
        expect(gloss['divPosition'], 'static',
            reason: 'TODO-1022: dict position:fixed on rendered gloss-sc-div '
                'must be filtered, got ${gloss['divPosition']}');

        // BUG-520 分行不变量：渲染出的 div 保持 block，两个 div 垂直堆叠。
        expect(gloss['divDisplay'], 'block',
            reason: 'BUG-520: rendered gloss-sc-div must keep UA block display '
                '(line breaks), got ${gloss['divDisplay']}');
        expect(gloss['divsStackVertically'], isTrue,
            reason: 'BUG-520: two rendered dict divs must stack vertically '
                '(line breaks), rects ${gloss['div1Rect']} / '
                '${gloss['div2Rect']}');

        // position:relative（行内微调）保留。
        expect(gloss['relPosition'], 'relative',
            reason: 'source filter must keep position:relative glyph nudges, '
                'got ${gloss['relPosition']}');

        // 反向对照：裸 gloss-sc-div（不经渲染管线、直接带 inline float）float 原样
        // 保留 —— 证明一刀切 CSS 已删，中和只发生在 popup.js 源头（BUG-520 守卫）。
        expect(gloss['bareDivFloat'], isNot('none'),
            reason: 'BUG-520: no blanket CSS may neutralize a bare '
                'gloss-sc-div; filtering happens only in the JS renderer, got '
                '${gloss['bareDivFloat']}');

        // 图片链接布局零回归：popup.css 仍给 .gloss-image-link position:relative。
        expect(gloss['imageLinkPosition'], 'relative',
            reason: 'TODO-859/350: .gloss-image-link must keep '
                'position:relative from popup.css, got '
                '${gloss['imageLinkPosition']}');

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

/// TODO-1022 / BUG-520 探针：在真弹窗文档里调用真实渲染管线
/// renderStructuredContent，验证源头过滤（float / position:absolute|fixed 不落地、
/// relative 保留）、div 分行不变量（display=block + 两 div 垂直堆叠），以及
/// 一刀切 CSS 已删（裸 gloss-sc-div 的 inline float 原样保留）。
String _glossaryNeutralizeProbeJs() => r'''
(function() {
  try {
    if (typeof renderStructuredContent !== 'function') {
      return JSON.stringify({ok: false, error: 'renderStructuredContent missing'});
    }
    var host = document.createElement('span');
    host.className = 'structured-content';
    host.setAttribute('data-verify-1022', '1');
    document.body.appendChild(host);

    // (a) 真渲染管线：float / position:absolute 在源头被过滤。
    renderStructuredContent(host,
      {tag: 'span', style: {float: 'right', position: 'absolute'}, content: 'Q'},
      'ja', 'VerifyDict', false);
    var scSpan = host.querySelector('.gloss-sc-span');

    // (b) 真渲染 div×2：display 保持 block、两行垂直堆叠（BUG-520 分行不变量）。
    renderStructuredContent(host,
      {tag: 'div', style: {float: 'left', position: 'fixed'}, content: 'LINE1'},
      'ja', 'VerifyDict', false);
    renderStructuredContent(host,
      {tag: 'div', content: 'LINE2'}, 'ja', 'VerifyDict', false);
    var divs = host.querySelectorAll('.gloss-sc-div');
    var d1 = divs[0];
    var d2 = divs[1];

    // (c) position:relative 行内微调保留。
    renderStructuredContent(host,
      {tag: 'span', style: {position: 'relative', top: '-6px'}, content: 'R'},
      'ja', 'VerifyDict', false);
    var spans = host.querySelectorAll('.gloss-sc-span');
    var relSpan = spans[spans.length - 1];

    // (d) 反向对照：裸 gloss-sc-div 带 inline float，不经渲染管线 —— 一刀切
    //     CSS 已删，float 应原样保留（中和只发生在 JS 源头）。
    var bare = document.createElement('div');
    bare.className = 'gloss-sc-div';
    bare.style.cssText = 'float:left;';
    bare.textContent = 'BARE';
    host.appendChild(bare);

    // (e) 图片链接布局零回归：popup.css 仍给 .gloss-image-link position:relative。
    var imgLink = document.createElement('a');
    imgLink.className = 'gloss-image-link';
    imgLink.textContent = 'IMG';
    host.appendChild(imgLink);

    void host.offsetHeight;

    var spanCs = window.getComputedStyle(scSpan);
    var d1Cs = window.getComputedStyle(d1);
    var relCs = window.getComputedStyle(relSpan);
    var bareCs = window.getComputedStyle(bare);
    var imgCs = window.getComputedStyle(imgLink);
    var r1 = d1.getBoundingClientRect();
    var r2 = d2.getBoundingClientRect();

    var result = {
      ok: true,
      spanFloat: spanCs.getPropertyValue('float') || spanCs.cssFloat || '',
      spanPosition: spanCs.getPropertyValue('position'),
      divFloat: d1Cs.getPropertyValue('float') || d1Cs.cssFloat || '',
      divPosition: d1Cs.getPropertyValue('position'),
      divDisplay: d1Cs.getPropertyValue('display'),
      relPosition: relCs.getPropertyValue('position'),
      bareDivFloat: bareCs.getPropertyValue('float') || bareCs.cssFloat || '',
      imageLinkPosition: imgCs.getPropertyValue('position'),
      div1Rect: {top: r1.top, bottom: r1.bottom},
      div2Rect: {top: r2.top, bottom: r2.bottom},
      divsStackVertically: r2.top >= r1.bottom - 1
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
