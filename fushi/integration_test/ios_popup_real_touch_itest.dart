import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/ios_real_touch.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-1692 iOS 侧：查词**浮层**里的 WKWebView 能否收到真实触摸（点击 / 拖拽）。
///
/// macOS 的根因是 `FlutterMutatorView` 按「平台视图之后的绘制」粗矩形吞掉鼠标；
/// iOS 3.47 的模型不同——`FlutterTouchInterceptingView.hitTest:` 同步问框架的命中
/// 路径里有没有平台视图。本用例在真 app 里走「首页词典查词 → 真触摸点结果区的词
/// → 弹出嵌套浮层 → 真触摸点浮层里的收藏 / 各区域 / 拖拽 / Flutter 关闭钮」，每一步
/// 读 DOM 侧 capture 探针，断言事件真的进了 WebKit。
///
/// 真实触摸由外部 XCUITest 投递（`support/ios_touch_tapper`），编排：
/// `TEST=integration_test/ios_popup_real_touch_itest.dart bash integration_test/support/run_sim_touch_itest.sh <udid>`
/// （Mac 上，在 `fushi/` 下）。导航仍是焦点驱动；坐标触摸只用于「指针能否到 DOM」
/// 这一件被测事实本身。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String installProbe = r'''
(() => {
  if (window.__touchProbe) { window.__touchProbe.length = 0; return 'reset'; }
  const log = [];
  window.__touchProbe = log;
  window.__touchProbeSwallow = false;
  for (const t of ['touchstart', 'touchmove', 'touchend', 'pointerdown',
                   'pointerup', 'click']) {
    window.addEventListener(t, (e) => {
      const p = (e.touches && e.touches[0]) ||
          (e.changedTouches && e.changedTouches[0]) || e;
      const el = e.target && e.target.nodeType === 1 ? e.target
          : (e.target && e.target.parentElement);
      log.push({t, x: Math.round(p.clientX), y: Math.round(p.clientY),
          tag: el ? el.tagName : null,
          cls: el && typeof el.className === 'string'
              ? el.className.slice(0, 48) : ''});
      // 区域扫描时吞掉事件，避免 popup.js 的点词 / 关子窗副作用改变后续状态。
      if (window.__touchProbeSwallow) {
        e.stopImmediatePropagation();
        if (e.cancelable) e.preventDefault();
      }
    }, {capture: true, passive: false});
  }
  return 'installed';
})()
''';

  Future<List<Map<String, Object?>>> readProbe(
    DictionaryPopupWebViewState web,
  ) async {
    final dynamic raw = await web.debugEval(
      'JSON.parse(JSON.stringify(window.__touchProbe || []))',
    );
    if (raw is! List) return <Map<String, Object?>>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
        .toList();
  }

  Future<void> resetProbe(DictionaryPopupWebViewState web) async {
    await web.debugEval(
      'window.__touchProbe && (window.__touchProbe.length = 0)',
    );
  }

  /// DOM 元素中心 → 全局逻辑坐标。CSS px 与逻辑 px 的比例用视口宽度换算。
  Future<Offset?> domCenter(
    WidgetTester tester,
    Element webElement,
    DictionaryPopupWebViewState web,
    String selector,
  ) async {
    dynamic raw;
    try {
      raw = await web.debugEval('''
(() => {
  const el = document.querySelector(${_jsString(selector)});
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return {x: r.left + r.width / 2, y: r.top + r.height / 2,
          w: r.width, h: r.height, iw: window.innerWidth};
})()
''');
    } catch (e) {
      debugPrint('[popup-touch] domCenter($selector) eval failed: $e');
      return null;
    }
    if (raw is! Map) return null;
    if (!webElement.mounted) {
      debugPrint(
        '[popup-touch] domCenter($selector): WebView element unmounted',
      );
      return null;
    }
    final RenderBox box = webElement.renderObject! as RenderBox;
    final Rect rect = box.localToGlobal(Offset.zero) & box.size;
    final double scale = rect.width / (raw['iw'] as num).toDouble();
    return rect.topLeft +
        Offset(
          (raw['x'] as num).toDouble() * scale,
          (raw['y'] as num).toDouble() * scale,
        );
  }

  /// 屏幕上可见（不在屏外热槽停放位）的查词 WebView。
  List<Element> visibleWebViews(WidgetTester tester) {
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Rect screenRect = Offset.zero & screen;
    return find.byType(DictionaryPopupWebView).evaluate().where((Element e) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize || ro.size.isEmpty) return false;
      final Rect r = ro.localToGlobal(Offset.zero) & ro.size;
      return r.overlaps(screenRect) && screenRect.contains(r.center);
    }).toList();
  }

  /// [box] 经各级祖先绘制裁剪后在屏幕上的可见矩形（全局逻辑坐标）。
  Rect visiblePaintRect(RenderBox box) {
    Rect visible = box.localToGlobal(Offset.zero) & box.size;
    RenderObject child = box;
    RenderObject? parent = box.parent;
    while (parent != null) {
      final Rect? clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), clip),
        );
      }
      child = parent;
      parent = parent.parent;
    }
    return visible;
  }

  /// 框架命中路径里是否有平台视图（[within] 非空时只认它子树里的那个）——与引擎
  /// `platformViewShouldAcceptTouchAtTouchBeganLocation` 的判据同源。
  bool frameworkPathHasPlatformView(Offset global, {Element? within}) {
    final HitTestResult result = HitTestResult();
    binding.hitTestInView(
      result,
      global,
      binding.platformDispatcher.implicitView!.viewId,
    );
    final RenderObject? root = within?.renderObject;
    return result.path.any((HitTestEntry e) {
      final Object target = e.target;
      if (target is! RenderUiKitView) return false;
      if (root == null) return true;
      for (RenderObject? n = target; n != null; n = n.parent) {
        if (identical(n, root)) return true;
      }
      return false;
    });
  }

  testWidgets('iOS lookup popup WebView receives real touches', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(await seedDictionary(tester), isTrue);

    expect(
      await driver.focusWidget(findNavTargetForTab(HomeTab.dictionaries)),
      isTrue,
    );
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    final HomeDictionarySearchDebug searchDebug =
        tester.state(find.byType(HomeDictionaryPage))
            as HomeDictionarySearchDebug;
    // 用生成词典里的日文词条「猫」：点结果区词头时嵌套查词从落点字符起扫描，单字
    // 词头必然命中同一词条（英文 testword 从中间字母起扫会落到无结果面板）。
    await searchDebug.debugSearch('猫', writeHistory: false);
    await tester.pump(const Duration(seconds: 5));

    final IosRealTouchSession touch = IosRealTouchSession.start(binding);
    try {
      // ── 1. 结果区：真触摸点词头，应弹出嵌套浮层 ──
      List<Element> shown = visibleWebViews(tester);
      expect(shown, isNotEmpty, reason: '查词结果区 WebView 必须可见');
      shown.sort(
        (Element a, Element b) => ((b.renderObject! as RenderBox).size.height)
            .compareTo((a.renderObject! as RenderBox).size.height),
      );
      final Element resultEl = shown.first;
      final DictionaryPopupWebViewState resultWeb =
          (resultEl as StatefulElement).state as DictionaryPopupWebViewState;
      Offset? word;
      for (int i = 0; i < 40 && word == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        word = await domCenter(tester, resultEl, resultWeb, '.expression');
      }
      expect(word, isNotNull, reason: '结果区必须渲染出词头 .expression');
      debugPrint(
        '[popup-touch] probe result ${await resultWeb.debugEval(installProbe)}',
      );
      debugPrint(
        '[popup-touch] result word at $word frameworkHasPV=${frameworkPathHasPlatformView(word!)}',
      );
      final Set<Element> before = visibleWebViews(tester).toSet();
      expect(
        await touch.touch(tester, word, timeout: const Duration(minutes: 5)),
        isTrue,
        reason: 'XCUITest 的触摸必须到达 Flutter（tapper 没起来？）',
      );
      await tester.pump(const Duration(milliseconds: 600));
      final List<Map<String, Object?>> resultEvents = await readProbe(
        resultWeb,
      );
      debugPrint('[popup-touch] RESULT-AREA events=$resultEvents');
      expect(
        resultEvents.map((Map<String, Object?> e) => e['t']),
        containsAll(<String>['touchstart', 'touchend', 'click']),
        reason: '结果区 WebView 必须收到真实触摸',
      );

      Element? popupEl;
      for (int i = 0; i < 40 && popupEl == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        for (final Element e in visibleWebViews(tester)) {
          final bool inLayer = find
              .ancestor(
                of: find.byElementPredicate((Element x) => x == e),
                matching: find.byType(DictionaryPopupLayer),
              )
              .evaluate()
              .isNotEmpty;
          if (inLayer && !before.contains(e)) popupEl = e;
        }
      }
      expect(popupEl, isNotNull, reason: '点结果区词头必须弹出嵌套查词浮层');
      final DictionaryPopupWebViewState popupWeb =
          (popupEl! as StatefulElement).state as DictionaryPopupWebViewState;
      final Rect popupBoxRect = tester.getRect(
        find.byElementPredicate((Element e) => e == popupEl),
      );
      // 浮层 WebView 的盒子比可见卡片高（webViewOverflowHeight 溢出部分被卡片裁掉），
      // 区域扫描只能落在**可见**部分——落到卡片外就是 barrier，会把浮层关掉。
      final Rect popupRect = visiblePaintRect(
        popupEl.renderObject! as RenderBox,
      );
      debugPrint(
        '[popup-touch] popup webview box=$popupBoxRect visible=$popupRect',
      );

      // ── 2. 浮层内：真触摸点收藏 ☆，DOM 收到事件且按钮状态翻转 ──
      Offset? fav;
      for (int i = 0; i < 40 && fav == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        fav = await domCenter(tester, popupEl, popupWeb, '.favorite-button');
      }
      if (fav == null) {
        debugPrint(
          '[popup-touch] popup DOM: ${await popupWeb.debugEval(r'''
(() => [document.readyState, location.href.slice(0, 80),
  document.querySelectorAll('button').length,
  Array.from(document.querySelectorAll('button')).slice(0, 8)
      .map((b) => b.className).join('|'),
  (document.body ? document.body.innerText : '').slice(0, 160)])()
''')}',
        );
      }
      expect(fav, isNotNull, reason: '浮层必须渲染出收藏按钮');
      debugPrint(
        '[popup-touch] probe popup ${await popupWeb.debugEval(installProbe)}',
      );
      const String favState =
          "document.querySelector('.favorite-button').classList.contains('favorited')";
      final dynamic favBefore = await popupWeb.debugEval(favState);
      expect(await touch.touch(tester, fav!), isTrue);
      await tester.pump(const Duration(milliseconds: 1200));
      final List<Map<String, Object?>> favEvents = await readProbe(popupWeb);
      final dynamic favAfter = await popupWeb.debugEval(favState);
      debugPrint(
        '[popup-touch] POPUP-FAVORITE at $fav frameworkHasPV=${frameworkPathHasPlatformView(fav, within: popupEl)} '
        'favorited $favBefore->$favAfter events=$favEvents',
      );
      expect(
        favEvents.map((Map<String, Object?> e) => e['t']),
        containsAll(<String>['touchstart', 'touchend', 'click']),
        reason: '浮层 WebView 必须收到点收藏的真实触摸',
      );
      expect(
        favEvents.any(
          (Map<String, Object?> e) =>
              e['t'] == 'click' &&
              (e['cls'] as String? ?? '').contains('favorite-button'),
        ),
        isTrue,
        reason: 'click 必须命中收藏按钮本身',
      );
      expect(favAfter, isNot(favBefore), reason: '收藏按钮状态必须翻转');

      // ── 3. 浮层内各区域扫描（吞事件模式）：DOM 收到 ⇔ 框架命中路径含平台视图 ──
      await popupWeb.debugEval('window.__touchProbeSwallow = true');
      final Rect inner = popupRect.deflate(8);
      final Map<String, Offset> points = <String, Offset>{
        'center': inner.center,
        'topLeft': inner.topLeft,
        'topRight': inner.topRight,
        'bottomLeft': inner.bottomLeft,
        'bottomRight': inner.bottomRight,
        'midLeft': inner.centerLeft,
        'midRight': inner.centerRight,
        'midBottom': inner.bottomCenter,
      };
      final List<String> mismatches = <String>[];
      int domHits = 0;
      for (final MapEntry<String, Offset> p in points.entries) {
        await resetProbe(popupWeb);
        final bool expectDom = frameworkPathHasPlatformView(
          p.value,
          within: popupEl,
        );
        expect(await touch.touch(tester, p.value), isTrue);
        await tester.pump(const Duration(milliseconds: 500));
        final List<Map<String, Object?>> ev = await readProbe(popupWeb);
        final bool gotDom = ev.any(
          (Map<String, Object?> e) => e['t'] == 'touchstart',
        );
        if (gotDom) domHits++;
        debugPrint(
          '[popup-touch] REGION ${p.key} at ${p.value} frameworkHasPV=$expectDom '
          'dom=$gotDom events=$ev',
        );
        if (gotDom != expectDom) {
          mismatches.add('${p.key}: fw=$expectDom dom=$gotDom');
        }
      }
      await popupWeb.debugEval('window.__touchProbeSwallow = false');
      expect(mismatches, isEmpty, reason: 'DOM 收触摸必须与框架命中判定一致');
      expect(
        domHits,
        greaterThanOrEqualTo(points.length - 1),
        reason: '浮层 WebView 绝大部分区域都必须收得到触摸（最多右下角让给尺寸把手）',
      );

      // ── 4. 浮层内拖拽：按住后横拖，DOM 收到 touchmove ──
      await resetProbe(popupWeb);
      // 竖拖：横拖会触发浮层的「滑动关闭」（_BodySwipeDismissDetector，iOS 默认开），
      // 那是产品行为，但会让后面的 × 步骤无从验证。
      final Offset dragFrom = Offset(inner.center.dx, inner.top + 40);
      final Offset dragTo = Offset(inner.center.dx + 4, inner.bottom - 12);
      expect(
        await touch.touch(tester, dragFrom, pressSeconds: 0.6, dragTo: dragTo),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final List<Map<String, Object?>> dragEvents = await readProbe(popupWeb);
      final dynamic selection = await popupWeb.debugEval(
        'String(window.getSelection ? window.getSelection() : "")',
      );
      debugPrint(
        '[popup-touch] POPUP-DRAG $dragFrom->$dragTo selection="$selection" '
        'moves=${dragEvents.where((Map<String, Object?> e) => e['t'] == 'touchmove').length} '
        'events=${dragEvents.where((Map<String, Object?> e) => e['t'] != 'touchmove').toList()}',
      );
      expect(
        dragEvents.where((Map<String, Object?> e) => e['t'] == 'touchmove'),
        isNotEmpty,
        reason: '浮层 WebView 必须收到拖拽的 touchmove',
      );
      expect(
        visibleWebViews(tester).contains(popupEl),
        isTrue,
        reason: '竖拖不应关闭浮层',
      );

      // ── 5. 浮层 Flutter 外壳：真触摸点 ×，浮层关闭 ──
      final Finder layer = find.ancestor(
        of: find.byElementPredicate((Element e) => e == popupEl),
        matching: find.byType(DictionaryPopupLayer),
      );
      expect(layer, findsWidgets, reason: '浮层此时必须仍挂载');
      final Finder close = find.descendant(
        of: layer.first,
        matching: find.byIcon(Icons.close),
      );
      if (close.evaluate().isNotEmpty) {
        final Offset c = tester.getCenter(close.first);
        expect(await touch.touch(tester, c), isTrue);
        await tester.pump(const Duration(seconds: 1));
        final bool stillShown = visibleWebViews(tester).contains(popupEl);
        debugPrint('[popup-touch] POPUP-CLOSE at $c stillShown=$stillShown');
        expect(stillShown, isFalse, reason: '点浮层 × 必须关闭浮层');
      } else {
        debugPrint('[popup-touch] POPUP-CLOSE skipped: no close icon in layer');
      }
      debugPrint('[popup-touch] DONE pointers=${touch.events.length}');
    } finally {
      touch.dispose();
    }
  });
}

String _jsString(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
