import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

import '../widgets/widget_test_helpers.dart';

/// 视频页查词框「弹出动画难受」（2026-09-27 用户录屏）的两个 Flutter 侧根因：
///
/// ① 顶层查词先画一张加载占位卡，结果渲染完真弹窗接替它时又从透明度 0 淡入——占位卡
///    同帧撤掉、真弹窗还半透明，中间露出一段透底空框。接替占位卡的那次翻可见必须直接
///    满不透明（[DictionaryPopupEntry.revealedOverSearchPlaceholder] → `fadeIn: false`）。
/// ② 自适应高度改外壳时连带改原生 WebView 表面尺寸，Windows 上新尺寸的帧晚到，旧帧被
///    Texture 拉伸（内容先放大一帧）。WebView 必须按最大高度布局、外壳只做裁剪
///    （[DictionaryPopupLayer.webViewOverflowHeight]）。
void main() {
  const Rect kRect = Rect.fromLTWH(10, 10, 4, 4);

  group('revealedOverSearchPlaceholder', () {
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

    test('渲染完成接替占位卡翻可见 → 标记为真', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: true);
      popup.markPendingReveal(target, onForcedReveal: () {});

      expect(popup.revealRendered(target), isTrue);
      expect(target.revealedOverSearchPlaceholder, isTrue);
    });

    test('没有占位卡（嵌套查词）翻可见 → 标记为假，照常淡入', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: false);
      popup.markPendingReveal(target, onForcedReveal: () {});

      expect(popup.revealRendered(target), isTrue);
      expect(target.revealedOverSearchPlaceholder, isFalse);
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

      expect(target.revealedOverSearchPlaceholder, isTrue);
    });

    test('上一次接替过占位卡，下一次无占位卡的翻可见会重新判定为假', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false);
      addTearDown(popup.dispose);
      final DictionaryPopupEntry target =
          beginWithPlaceholder(popup, placeholder: true);
      popup.markPendingReveal(target, onForcedReveal: () {});
      popup.revealRendered(target);
      popup.endSearchUi();
      expect(target.revealedOverSearchPlaceholder, isTrue);

      popup.markPendingReveal(target, onForcedReveal: () {});
      popup.revealRendered(target);
      expect(target.revealedOverSearchPlaceholder, isFalse);
    });
  });

  group('parkedPopupLayer fadeIn', () {
    Widget host({required bool visible, required bool fadeIn}) {
      return buildTestApp(
        SizedBox(
          width: 400,
          height: 400,
          child: Stack(
            children: <Widget>[
              parkedPopupLayer(
                pos: const Rect.fromLTWH(0, 0, 200, 100),
                visible: visible,
                fadeIn: fadeIn,
                screen: const Size(400, 400),
                child: const SizedBox.expand(),
              ),
            ],
          ),
        ),
      );
    }

    double opacityOf(WidgetTester tester) => tester
        .renderObject<RenderAnimatedOpacity>(find.byType(AnimatedOpacity))
        .opacity
        .value;

    testWidgets('默认：隐藏 → 可见从 0 淡入', (WidgetTester tester) async {
      await tester.pumpWidget(host(visible: false, fadeIn: true));
      await tester.pumpWidget(host(visible: true, fadeIn: true));
      expect(opacityOf(tester), 0.0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(opacityOf(tester), inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1.0);
    });

    testWidgets('fadeIn=false：首个可见帧即满不透明', (WidgetTester tester) async {
      await tester.pumpWidget(host(visible: false, fadeIn: false));
      await tester.pumpWidget(host(visible: true, fadeIn: false));
      await tester.pump();
      expect(opacityOf(tester), 1.0);
    });

    testWidgets('加载占位卡的入场淡入：挂载即从 0 补间到 1', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(popupEntranceFade(child: const SizedBox(width: 10))),
      );
      expect(opacityOf(tester), 0.0);
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1.0);
    });
  });

  group('popupWebViewOverflow', () {
    const Key probe = ValueKey<String>('webview');

    Future<void> pumpBody(WidgetTester tester, double overflow) {
      return tester.pumpWidget(
        buildTestApp(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 200,
              child: popupWebViewOverflow(
                overflowHeight: overflow,
                webView: const SizedBox.expand(key: probe),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('WebView 比可见区多布局出 overflow、顶端对齐且被裁剪', (
      WidgetTester tester,
    ) async {
      await pumpBody(tester, 0);
      final Size base = tester.getSize(find.byKey(probe));
      final Offset baseTop = tester.getTopLeft(find.byKey(probe));

      await pumpBody(tester, 120);
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
      expect(tester.takeException(), isNull);
    });

    testWidgets('overflow=0：不包裹，与改前布局一致', (WidgetTester tester) async {
      await pumpBody(tester, 0);
      expect(
        find.ancestor(
            of: find.byKey(probe), matching: find.byType(OverflowBox)),
        findsNothing,
      );
      expect(tester.getSize(find.byKey(probe)), const Size(300, 200));
    });
  });
}
