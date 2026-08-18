import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// 查词 WebView「真实指针能不能命中」的 DOM 侧探针。
///
/// 用户报「查词框点哪儿都没反应」（macOS / iOS）。既有的
/// `popup_dictionary_test.dart` 用 `element.click()` 直接派发事件，**绕过命中测试**，
/// 因此视口塌陷、内容被盖、`pointer-events` 被关这三种情况它一种都测不出来。
///
/// 本探针改用 `document.elementFromPoint()`——它和真实点击共用同一套 DOM 命中
/// 逻辑：坐标必须落在**视口**内，且该点最上层元素必须是目标自身。
///
/// 覆盖面注意（BUG-1692 实测）：本探针测的是**查词结果区**的 WebView。结果区与
/// 嵌套查词浮层虽是同一个 [DictionaryPopupWebView] 组件，但真机实测二者**结论不
/// 通用**——结果区收得到指针、浮层收不到。浮层挂在根 Overlay 且外面多套了
/// Visibility / 入场淡入 / 滑关 Listener，命中链不同。浮层侧的守卫需另写，别拿本
/// 用例的绿当成「浮层也能点」。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dictionary WebView controls are reachable by real hit-testing',
      (WidgetTester tester) async {
    app.main();

    expect(await waitForHome(tester), isTrue,
        reason: 'Home must render before probing the dictionary WebView');
    await tester.pump(const Duration(seconds: 2));

    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);

    expect(await seedDictionary(tester), isTrue,
        reason: 'generated popup-action fixture must be installed');

    final Finder dictionaryTab = findNavTargetForTab(HomeTab.dictionaries);
    expect(await driver.focusWidget(dictionaryTab), isTrue,
        reason: 'Dictionary tab must be reachable by focus');
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    final Element anyElement = tester.element(find.byType(Scaffold).first);
    final AppModel appModel =
        ProviderScope.containerOf(anyElement).read(appProvider);
    debugPrint('[hittest-probe] appUiScale=${appModel.appUiScale}');

    final HomeDictionarySearchDebug searchDebug = tester
        .state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;
    await searchDebug.debugSearch('testword', writeHistory: false);
    await tester.pump(const Duration(seconds: 5));

    final Finder webViewFinder = find.byType(DictionaryPopupWebView);
    expect(webViewFinder, findsWidgets,
        reason: 'dictionary result WebView must be mounted after a search');
    final DictionaryPopupWebViewState webView =
        tester.state(webViewFinder.first) as DictionaryPopupWebViewState;

    // 探针脚本：视口尺寸 + 按钮矩形 + 该矩形中心的真实命中结果。
    // `hitIsSelf` 为 true 才代表用户点在按钮上真能点到它。
    const String probeSource = r'''
(() => {
  const probe = (selector) => {
    const el = document.querySelector(selector);
    if (!el) return {present: false};
    const r = el.getBoundingClientRect();
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    const hit = document.elementFromPoint(cx, cy);
    return {
      present: true,
      rect: [r.left, r.top, r.width, r.height],
      center: [cx, cy],
      inViewport: cy >= 0 && cy <= (window.innerHeight || 0) &&
                  cx >= 0 && cx <= (window.innerWidth || 0),
      hitTag: hit ? hit.tagName : null,
      hitIsSelf: !!hit && (hit === el || el.contains(hit) || hit.contains(el)),
      pointerEvents: getComputedStyle(el).pointerEvents,
    };
  };
  return {
    ready: document.readyState,
    innerHeight: window.innerHeight,
    innerWidth: window.innerWidth,
    clientHeight: document.documentElement.clientHeight,
    clientWidth: document.documentElement.clientWidth,
    visualViewportHeight:
        window.visualViewport ? window.visualViewport.height : -1,
    contentHeight: Math.max(
        document.body.scrollHeight, document.documentElement.scrollHeight),
    bodyPointerEvents: getComputedStyle(document.body).pointerEvents,
    favorite: probe('.favorite-button'),
    mine: probe('.mine-button'),
  };
})()
''';

    Map<Object?, Object?>? probe;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final dynamic raw = await webView.debugEval(probeSource);
      if (raw is Map && raw['favorite'] is Map) {
        final Map<Object?, Object?> favorite =
            (raw['favorite'] as Map).cast<Object?, Object?>();
        if (favorite['present'] == true) {
          probe = raw.cast<Object?, Object?>();
          break;
        }
      }
    }

    debugPrint('[hittest-probe] $probe');
    expect(probe, isNotNull,
        reason: 'dictionary WebView must render the favorite control');

    // 视口塌陷是「点哪儿都没反应」的最直接机制：坐标落在 0 高视口外，命中恒空。
    expect(
      (probe!['innerHeight']! as num).toDouble(),
      greaterThan(0),
      reason: 'WKWebView 视口高为 0 时 DOM 命中测试整体落空，真实点击点不到任何'
          '元素（JS 直接 .click() 仍会成功，故旧测试测不出）',
    );

    for (final String key in <String>['favorite', 'mine']) {
      final Map<Object?, Object?> control =
          (probe[key]! as Map).cast<Object?, Object?>();
      expect(control['present'], isTrue, reason: '$key 按钮必须存在');
      expect(control['pointerEvents'], isNot('none'),
          reason: '$key 按钮的 pointer-events 被关掉则永远收不到点击');
      expect(control['inViewport'], isTrue,
          reason: '$key 按钮中心必须落在视口内，否则真实点击不可达：$control');
      expect(control['hitIsSelf'], isTrue,
          reason: '$key 按钮中心的命中结果必须是它自己（被遮挡或视口塌陷都会失败）：'
              '$control');
    }
  });
}
