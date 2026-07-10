import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

import '../widgets/widget_test_helpers.dart';

/// TODO-1353 guard: Ctrl+滚轮在查词弹窗内缩放内容（改词典字号，持久化）。
///
/// 缩放本体（documentElement.style.zoom）注入进 WebView、归设备集成验证；此处锁：
///  1. 词典字号的步进 / 夹紧纯函数（[steppedPopupZoomFontSize] /
///     [clampPopupZoomFontSize]）——JS wheel 监听与 Dart 持久化两侧共用同一语义。
///  2. 源码里 Ctrl+滚轮监听（`_zoomWheelJs`）、其 onLoadStop 注入、`popupZoomFont`
///     回调、以及 buildPopupSettingsJs 暴露的 `__hoshiPopupFontSize/UiScale` 都在位，
///     防止后续重构悄悄拆掉某一环导致缩放不生效 / 不持久化。
///  3. TODO-1353 复诉：弹窗顶栏必须有**可见的** A−/A+ 手动字号按钮（触屏没有
///     Ctrl+滚轮，这是移动端唯一入口）+ 可见 Tooltip 提示（桌面附带
///     dictionary_font_size_zoom_hint），且按钮与滚轮共用同一 JS 步进
///     `window.__hoshiPopupZoomStep`（夹紧 / 即时 zoom / 持久化语义不漂移）。
void main() {
  group('DictionaryPopupWebViewState 字号步进/夹紧 (TODO-1353)', () {
    test('上滚放大一档、下滚缩小一档（16 基准）', () {
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(16, zoomIn: true),
        17,
      );
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(16, zoomIn: false),
        15,
      );
    });

    test('夹到 [8, 72] 区间，杜绝缩没 / 撑爆', () {
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(1000), 72);
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(2), 8);
      // 步进在边界处不越界。
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(72, zoomIn: true),
        72,
      );
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(8, zoomIn: false),
        8,
      );
    });

    test('非法（非有限 / 非正）字号回退默认 16', () {
      expect(
        DictionaryPopupWebViewState.clampPopupZoomFontSize(double.nan),
        16,
      );
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(0), 16);
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(-5), 16);
    });
  });

  group('Ctrl+滚轮缩放接线在位 (TODO-1353)', () {
    final String webviewSrc = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final String injectionSrc = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();

    test('wheel 监听只在 ctrlKey 时拦截并 preventDefault', () {
      expect(webviewSrc.contains('__hoshiZoomWheelInstalled'), isTrue);
      expect(webviewSrc.contains("addEventListener('wheel'"), isTrue);
      expect(webviewSrc.contains('e.ctrlKey'), isTrue);
      expect(webviewSrc.contains('e.preventDefault()'), isTrue);
    });

    test('监听在 onLoadStop 注入、并有 popupZoomFont 持久化回调', () {
      expect(
        webviewSrc.contains('evaluateJavascript(source: _zoomWheelJs)'),
        isTrue,
      );
      expect(webviewSrc.contains("handlerName: 'popupZoomFont'"), isTrue);
      expect(webviewSrc.contains('setDictionaryFontSize('), isTrue);
    });

    test('注入体暴露 __hoshiPopupFontSize / __hoshiPopupUiScale 供 JS 就地算 zoom', () {
      expect(injectionSrc.contains('window.__hoshiPopupFontSize'), isTrue);
      expect(injectionSrc.contains('window.__hoshiPopupUiScale'), isTrue);
    });

    test('步进本体收口 window.__hoshiPopupZoomStep：wheel 与 A−/A+ 共用一条路径', () {
      // JS 侧唯一步进实现（夹紧 + 就地 zoom + popupZoomFont 持久化）……
      expect(
        webviewSrc.contains('window.__hoshiPopupZoomStep = function(dir)'),
        isTrue,
      );
      // ……wheel 监听调它……
      expect(
        webviewSrc
            .contains('window.__hoshiPopupZoomStep(e.deltaY < 0 ? 1 : -1)'),
        isTrue,
      );
      // ……Dart 手动按钮入口也调它（不得另写一份步进语义）。
      expect(
        webviewSrc.contains('void zoomFontStep({required bool zoomIn})'),
        isTrue,
      );
    });
  });

  group('弹窗顶栏可见 A−/A+ 手动字号控件 (TODO-1353 复诉)', () {
    final String layerSrc = File(
      'lib/src/pages/implementations/dictionary_popup_layer.dart',
    ).readAsStringSync();

    testWidgets('顶栏渲染 A−/A+ 按钮，Tooltip 提示可见，点按安全', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          SizedBox(
            width: 320,
            height: 240,
            child: DictionaryPopupLayer(
              // result=null + 非搜索 → body 走「未找到搜索结果」占位分支（不挂真
              // WebView，headless 可跑）；顶栏（chrome）与内容无关照常渲染。
              result: null,
              isSearching: false,
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              onDismiss: () {},
              onClose: () {},
              onTextSelected: (String text, Rect rect) {},
              onLinkClick: (String query, Rect rect) {},
              onMineEntry: (Map<String, String> fields) async =>
                  const MinePopupResult(),
              onDuplicateCheck: (String expression, String reading) async =>
                  false,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      // 控件存在：A−（text_decrease）与 A+（text_increase）各一。
      expect(find.byIcon(Icons.text_decrease), findsOneWidget);
      expect(find.byIcon(Icons.text_increase), findsOneWidget);

      // 可见提示：两个按钮都包着 [Tooltip]；flutter test 宿主必为桌面平台，消息
      // 必须附带「Ctrl+滚轮也可缩放」提示（dictionary_font_size_zoom_hint）。
      final Iterable<String> tooltipMessages = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((Tooltip w) => w.message)
          .whereType<String>();
      expect(
        tooltipMessages
            .where((String m) => m.contains(t.dictionary_font_size_zoom_hint))
            .length,
        2,
        reason: '桌面上 A−/A+ 的 Tooltip 必须带 Ctrl+滚轮提示',
      );

      // 点按走 [DictionaryPopupWebViewState.zoomFontStep]：WebView 未挂载
      // （无结果占位）时必须安全 no-op，不得抛异常。
      await tester.tap(find.byIcon(Icons.text_increase));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.text_decrease));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    test('按钮接线：走 zoomFontStep（与滚轮同一路径）且桌面 Tooltip 附带滚轮提示', () {
      // 点按必须经 zoomFontStep → __hoshiPopupZoomStep（同夹紧 [8,72]、同持久化），
      // 不得在 layer 里另算字号。
      expect(layerSrc.contains('zoomFontStep(zoomIn: zoomIn)'), isTrue);
      expect(layerSrc.contains('Icons.text_decrease'), isTrue);
      expect(layerSrc.contains('Icons.text_increase'), isTrue);
      // 可见提示（桌面平台附带 dictionary_font_size_zoom_hint）。
      expect(layerSrc.contains('dictionary_font_size_zoom_hint'), isTrue);
      expect(layerSrc.contains('Tooltip('), isTrue);
    });
  });
}
