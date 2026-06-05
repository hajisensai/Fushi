import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// 视频查词浮层「调整界面大小后字糊」修复（BUG-051）的守卫，不依赖 media_kit/libmpv。
///
/// **根因**：查词浮层渲染在**根 Overlay**（在 [HibikiAppUiScale] 的 `FittedBox` 之内
/// ＝缩放后的小画布 `view/s`）。浮层的词典 WebView 在小画布尺寸栅格化、再被外层
/// `FittedBox` 拉大 → 字糊（与 BUG-039 阅读器同源）。
///
/// **修法**：[VideoHibikiPage._buildPopupOverlay] 把整棵浮层子树用
/// [HibikiAppUiScaleNeutralizer] 中和回**真实视口尺寸、净缩放=1**，WebView 按原生像素
/// 密度渲染＝清晰；坐标随之统一到真实屏幕空间，故 `_lookupAt` **直接**用 `localToGlobal`
/// 的字符屏幕 rect 定位（不再经 `scaledRectToCanvas` ÷s 换算到画布）。
///
/// 「字糊」本身是 WebView 纹理分辨率，属设备级肉眼项；中和器把子树净缩放归 1（原生密度）
/// 已由 `app_ui_scale_neutralizer_test.dart` 单测。本文件守的是**接线 + 坐标自洽**：
/// 1. 行为：中和后的浮层用屏幕 rect 定位，浮层在**屏幕上**紧贴被点字符（任意缩放都不偏）；
/// 2. 对照（红）：去掉中和器、同样直传屏幕 rect，浮层会偏 factor s（证明中和器不可省）；
/// 3. 源码守卫：`_buildPopupOverlay` 含 `HibikiAppUiScaleNeutralizer`、全页不再 `scaledRectToCanvas`。
void main() {
  const Size physical = Size(1000, 800);

  /// 复刻 main.dart 的层级：[HibikiAppUiScale] 在根 Navigator/Overlay 之外
  /// （`FittedBox` 之内才是根 Overlay）。这里用 MaterialApp 提供根 Overlay，外层套缩放。
  Widget harness({required double scale, required Widget home}) =>
      HibikiAppUiScale(scale: scale, child: MaterialApp(home: home));

  /// 在 [pageContext] 的根 Overlay 插入一层定位浮层（[neutralize] 决定是否中和），浮层
  /// 定位到 [selectionRect]（生产里即字符的 `localToGlobal` 屏幕 rect）。返回 (浮层 box 的
  /// 屏幕 global rect, OverlayEntry)。
  Future<(Rect, OverlayEntry)> insertPopup(
    WidgetTester tester,
    BuildContext pageContext, {
    required Rect selectionRect,
    required bool neutralize,
  }) async {
    final GlobalKey popupKey = GlobalKey();
    Widget overlayChild = LayoutBuilder(
      builder: (BuildContext _, BoxConstraints cons) {
        final Rect pos = calcPopupPosition(
          selectionRect: selectionRect,
          screen: Size(cons.maxWidth, cons.maxHeight),
          maxWidth: 360,
          maxHeight: 360,
        );
        return Stack(
          children: <Widget>[
            Positioned(
              left: pos.left,
              top: pos.top,
              width: pos.width,
              height: pos.height,
              child: SizedBox(key: popupKey),
            ),
          ],
        );
      },
    );
    // 生产 _buildPopupOverlay 用中和器包裹整棵浮层子树。
    if (neutralize) {
      overlayChild = HibikiAppUiScaleNeutralizer(child: overlayChild);
    }
    final OverlayEntry entry = OverlayEntry(builder: (BuildContext _) {
      return overlayChild;
    });
    Overlay.of(pageContext, rootOverlay: true).insert(entry);
    await tester.pumpAndSettle();
    final Rect rect = globalRectOfBox(
        popupKey.currentContext!.findRenderObject()! as RenderBox);
    return (rect, entry);
  }

  testWidgets(
      'neutralized overlay + raw screen rect: popup hugs the tapped char ON '
      'SCREEN across scales', (WidgetTester tester) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final double scale in <double>[1.0, 1.5, 0.8]) {
      final GlobalKey charKey = GlobalKey();
      final GlobalKey pageKey = GlobalKey();
      await tester.pumpWidget(harness(
        scale: scale,
        home: Stack(
          key: pageKey,
          children: <Widget>[
            // 一个「字符」box，画布坐标 (300,200) 大小 40x50。
            Positioned(
              left: 300,
              top: 200,
              width: 40,
              height: 50,
              child: SizedBox(key: charKey),
            ),
          ],
        ),
      ));

      final BuildContext pageContext = pageKey.currentContext!;
      // 字符 box 的屏幕 rect（localToGlobal，已被 FittedBox ×s），即 _lookupAt 拿到的 rect。
      final Rect charScreen = globalRectOfBox(
          charKey.currentContext!.findRenderObject()! as RenderBox);

      final (Rect popupScreen, OverlayEntry entry) = await insertPopup(
        tester,
        pageContext,
        selectionRect: charScreen, // 生产直传屏幕 rect，不换算
        neutralize: true,
      );

      // 浮层在屏幕上紧贴字符下方（calcPopupPosition 下方 +4），任意缩放都对齐。
      expect(popupScreen.left, closeTo(charScreen.left, 2.0),
          reason: 'popup x must align with the char on screen at scale $scale');
      expect(popupScreen.top, closeTo(charScreen.bottom + 4, 2.0),
          reason: 'popup must sit just below the char on screen at $scale');

      entry.remove();
      entry.dispose();
      await tester.pump();
    }
  });

  testWidgets(
      'WITHOUT the neutralizer the same raw screen rect lands the popup off by '
      'the scale factor (proves the neutralizer is required)',
      (WidgetTester tester) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double scale = 1.5;
    final GlobalKey charKey = GlobalKey();
    final GlobalKey pageKey = GlobalKey();
    await tester.pumpWidget(harness(
      scale: scale,
      home: Stack(
        key: pageKey,
        children: <Widget>[
          Positioned(
            left: 300,
            top: 200,
            width: 40,
            height: 50,
            child: SizedBox(key: charKey),
          ),
        ],
      ),
    ));
    final BuildContext pageContext = pageKey.currentContext!;
    final Rect charScreen = globalRectOfBox(
        charKey.currentContext!.findRenderObject()! as RenderBox);

    final (Rect popupScreen, OverlayEntry entry) = await insertPopup(
      tester,
      pageContext,
      selectionRect: charScreen,
      neutralize: false, // 旧 bug：浮层在缩放画布空间，屏幕 rect 当画布坐标 → 偏 s
    );

    // 非中和：浮层不再紧贴字符下方，纵向明显偏离（off by factor s）。
    expect((popupScreen.top - (charScreen.bottom + 4)).abs(), greaterThan(50),
        reason: 'without neutralizer the popup is misplaced by the scale');

    entry.remove();
    entry.dispose();
    await tester.pump();
  });

  test(
      '_buildPopupOverlay wraps the popup in HibikiAppUiScaleNeutralizer and '
      'the manual scaledRectToCanvas conversion is gone', () {
    final String page = File(
      'lib/src/pages/implementations/video_hibiki_page.dart',
    ).readAsStringSync();
    expect(page.contains('HibikiAppUiScaleNeutralizer('), isTrue,
        reason: 'video popup overlay must be neutralized for native density');
    expect(page.contains('scaledRectToCanvas'), isFalse,
        reason: 'neutralized overlay uses the raw screen rect directly');

    // 中和器接管坐标后，手动换算 helper 已删除（消除特例，不留死代码）。
    final String util =
        File('lib/src/utils/app_ui_scale.dart').readAsStringSync();
    expect(util.contains('scaledRectToCanvas'), isFalse);
  });
}
