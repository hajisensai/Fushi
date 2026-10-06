import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

import '../helpers/source_guard.dart';
import '../widgets/widget_test_helpers.dart';

/// 视频页查词框「弹出动画难受」（BUG-2734，2026-09-27 用户录屏）的两个 Flutter 侧根因：
///
/// ① 顶层查词先画一张加载占位卡，结果渲染完真弹窗接替它时又从透明度 0 淡入——占位卡
///    同帧撤掉、真弹窗还半透明，中间露出一段透底空框；直接满不透明又会让快速查词「跳」
///    一下。接替占位卡的那次翻可见必须接着占位卡的淡入进度淡完
///    （[DictionaryPopupEntry.searchPlaceholderShownFor] → [popupEntranceProgressAfter]）。
/// ② 自适应高度改外壳时连带改原生 WebView 表面尺寸，Windows 上新尺寸的帧晚到，旧帧被
///    Texture 拉伸（内容先放大一帧）。WebView 必须按最大高度布局、外壳只做裁剪
///    （[DictionaryPopupLayer.webViewOverflowHeight]），并把可见高度交给 popup.js。
void main() {
  const Rect kRect = Rect.fromLTWH(10, 10, 4, 4);

  group('searchPlaceholderShownFor', () {
    DictionaryPopupEntry beginWithPlaceholder(
      DictionaryPopupController popup, {
      required bool placeholder,
    }) {
      final DictionaryPopupEntry target = popup.beginTop(
        term: 'テスト',
        rect: kRect,
        reuseWarmSlot: true,
        replaceStack: true,
        visible: false,
      );
      if (placeholder) popup.beginSearchUi(kRect, target);
      return target;
    }

    test('渲染完成接替占位卡翻可见 → 记下占位卡已显示的时长', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: true);
      popup.markPendingReveal(target, onForcedReveal: () {});

      expect(popup.revealRendered(target), isTrue);
      expect(target.searchPlaceholderShownFor, isNotNull);
      expect(target.searchPlaceholderShownFor,
          lessThan(const Duration(seconds: 5)));
    });

    test('没有占位卡（嵌套查词）翻可见 → null，照常从 0 淡入', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: false);
      popup.markPendingReveal(target, onForcedReveal: () {});

      expect(popup.revealRendered(target), isTrue);
      expect(target.searchPlaceholderShownFor, isNull);
    });

    test('空结果路径 fillResult 先清 isSearching 再 show，仍认得占位卡', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: true);
      popup.fillResult(
        target,
        result: kPopupSearchingPlaceholderResult,
        allLoaded: true,
      );
      popup.show(target);

      expect(target.searchPlaceholderShownFor, isNotNull);
    });

    test('上一次接替过占位卡，下一次无占位卡的翻可见会重新判定为 null', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: true);
      popup.markPendingReveal(target, onForcedReveal: () {});
      popup.revealRendered(target);
      popup.endSearchUi();
      expect(target.searchPlaceholderShownFor, isNotNull);

      popup.markPendingReveal(target, onForcedReveal: () {});
      popup.revealRendered(target);
      expect(target.searchPlaceholderShownFor, isNull);
    });
  });

  group('popupEntranceProgressAfter', () {
    test('null / 非正 → 0；超过淡入时长 → 1；其间线性', () {
      expect(popupEntranceProgressAfter(null), 0.0);
      expect(popupEntranceProgressAfter(Duration.zero), 0.0);
      expect(
          popupEntranceProgressAfter(const Duration(milliseconds: 100)), 0.5);
      expect(popupEntranceProgressAfter(const Duration(seconds: 3)), 1.0);
    });
  });

  group('parkedPopupLayer 入场淡入', () {
    const Key kChild = ValueKey<String>('popup-child');
    Widget host({required bool visible, double start = 0.0}) {
      return buildTestApp(
        SizedBox(
          width: 400,
          height: 400,
          child: Stack(
            children: <Widget>[
              parkedPopupLayer(
                pos: const Rect.fromLTWH(0, 0, 200, 100),
                visible: visible,
                entranceStartProgress: start,
                screen: const Size(400, 400),
                child: const SizedBox.expand(key: kChild),
              ),
            ],
          ),
        ),
      );
    }

    // MaterialApp 的路由过渡里也有 FadeTransition：从被测子节点往上找最近的那个。
    double opacityOf(WidgetTester tester) => tester
        .renderObject<RenderAnimatedOpacity>(find
            .ancestor(
                of: find.byKey(kChild), matching: find.byType(FadeTransition))
            .first)
        .opacity
        .value;

    testWidgets('默认：隐藏 → 可见从 0 淡入到 1', (WidgetTester tester) async {
      await tester.pumpWidget(host(visible: false));
      await tester.pumpWidget(host(visible: true));
      expect(opacityOf(tester), 0.0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(opacityOf(tester), inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1.0);
    });

    testWidgets('接替占位卡：首个可见帧就是占位卡当前的透明度，再接着淡完', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(visible: false));
      await tester.pumpWidget(host(visible: true, start: 0.5));
      final double first = opacityOf(tester);
      expect(first, closeTo(Curves.easeOut.transform(0.5), 1e-9),
          reason: '不从 0 重来（露底），也不直接跳满');
      await tester.pump(const Duration(milliseconds: 50));
      expect(opacityOf(tester), greaterThan(first));
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacityOf(tester), 1.0, reason: '剩余时长按比例缩短（100ms 走完）');
    });

    testWidgets('从没可见过的层（热槽 / 停驻 realm）卸载不抛', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(visible: false));
      await tester.pumpWidget(buildTestApp(const SizedBox()));
      expect(tester.takeException(), isNull);
    });

    testWidgets('隐藏即复位，下次可见重新淡入', (WidgetTester tester) async {
      await tester.pumpWidget(host(visible: true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(visible: false));
      expect(opacityOf(tester), 0.0);
      await tester.pumpWidget(host(visible: true));
      expect(opacityOf(tester), 0.0);
    });

    testWidgets('加载占位卡的入场淡入：挂载即从 0 淡到 1', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          popupEntranceFade(child: const SizedBox(key: kChild, width: 10)),
        ),
      );
      expect(opacityOf(tester), 0.0);
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1.0);
    });
  });

  group('popupWebViewOverflow', () {
    const Key probe = ValueKey<String>('webview');

    Future<List<double?>> pumpBody(WidgetTester tester, double overflow) async {
      final List<double?> visible = <double?>[];
      await tester.pumpWidget(
        buildTestApp(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 200,
              child: popupWebViewOverflow(
                overflowHeight: overflow,
                builder: (double? visibleHeight) {
                  visible.add(visibleHeight);
                  return const SizedBox.expand(key: probe);
                },
              ),
            ),
          ),
        ),
      );
      return visible;
    }

    testWidgets('WebView 比可见区多布局出 overflow、顶端对齐且被裁剪，可见高度交给 JS', (
      WidgetTester tester,
    ) async {
      await pumpBody(tester, 0);
      final Size base = tester.getSize(find.byKey(probe));
      final Offset baseTop = tester.getTopLeft(find.byKey(probe));

      final List<double?> visible = await pumpBody(tester, 120);
      final Size grown = tester.getSize(find.byKey(probe));
      expect(grown.width, base.width);
      expect(grown.height, base.height + 120);
      expect(tester.getTopLeft(find.byKey(probe)), baseTop,
          reason: '顶端对齐：内容起点不随外壳高度变化');
      final Finder clip = find.ancestor(
        of: find.byKey(probe),
        matching: find.byType(ClipRect),
      );
      expect(clip, findsOneWidget);
      expect(tester.getSize(clip).height, base.height);
      expect(visible.last, base.height, reason: '可见高度 = 裁剪框高度');
      expect(tester.takeException(), isNull);
    });

    testWidgets('overflow=0：结构不变（同一层 ClipRect/OverflowBox）、取原高、不注入可见高度', (
      WidgetTester tester,
    ) async {
      final List<double?> visible = await pumpBody(tester, 0);
      expect(
        find.ancestor(
            of: find.byKey(probe), matching: find.byType(OverflowBox)),
        findsOneWidget,
        reason: '溢出归零时 WebView 不能换树深度（平台视图重建闪烁）',
      );
      expect(tester.getSize(find.byKey(probe)), const Size(300, 200));
      expect(visible.last, isNull);
    });

    testWidgets('溢出在 0 与非 0 之间切换，WebView 的 Element 保持同一个', (
      WidgetTester tester,
    ) async {
      await pumpBody(tester, 0);
      final Element before = tester.element(find.byKey(probe));
      await pumpBody(tester, 80);
      expect(tester.element(find.byKey(probe)), same(before));
      await pumpBody(tester, 0);
      expect(tester.element(find.byKey(probe)), same(before));
    });
  });

  group('mixin 接线（源码守卫）', () {
    final String src = maskComments(
      File('lib/src/pages/implementations/dictionary_page_mixin.dart')
          .readAsStringSync(),
    );

    test('buildNestedPopupLayer 把溢出高度交给 DictionaryPopupLayer', () {
      expect(
          src.contains('webViewOverflowHeight: webViewOverflowHeight'), isTrue);
    });

    test('接替占位卡的淡入进度来自 entry.searchPlaceholderShownFor', () {
      expect(
        RegExp(r'entranceStartProgress:\s*popupEntranceProgressAfter\(\s*'
                r'entry\.searchPlaceholderShownFor\s*\)')
            .hasMatch(src),
        isTrue,
      );
    });

    test('自适应高度以 WebView 实际布局高度对应的外壳（fullPopupHeight）为基准', () {
      expect(
        RegExp(r'currentPopupHeight:\s*fullPopupHeight').hasMatch(src),
        isTrue,
        reason: 'JS 上报的视口是 WebView 布局高度，拿裁剪后的 pos.height 作差会收错',
      );
      expect(
          RegExp(r'currentPopupHeight:\s*pos\.height').hasMatch(src), isFalse);
    });

    test('搜索占位卡走入场淡入', () {
      expect(
        RegExp(r'popupEntranceFade\(\s*child:\s*FushiPopupSurface\(')
            .hasMatch(src),
        isTrue,
      );
    });
  });
}
