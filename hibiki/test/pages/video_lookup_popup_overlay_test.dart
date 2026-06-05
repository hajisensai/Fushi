import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// 视频查词浮层两处修复的单元守卫，不依赖 media_kit/libmpv：
///
/// 1. **缩放偏移**：字符 rect 来自 `localToGlobal`（HibikiAppUiScale 缩放后屏幕坐标），
///    浮层定位用根 Overlay 的逻辑画布坐标系；[scaledRectToCanvas] 必须把前者换算到
///    后者，使浮层定位到字符附近（界面非 100% 缩放也不偏）。
/// 2. **根 Overlay 渲染**：浮层用 `Overlay.of(context, rootOverlay: true)` 插入，浮在
///    页面 Stack（及 media_kit 全屏路由）之上。
void main() {
  /// 复刻 main.dart 的层级：HibikiAppUiScale 在根 Navigator/Overlay 之外（FittedBox
  /// 之内是根 Overlay）。这里用 MaterialApp 提供根 Overlay，外层套缩放。
  Widget harness({required double scale, required Widget home}) =>
      HibikiAppUiScale(
        scale: scale,
        child: MaterialApp(home: home),
      );

  testWidgets(
      'char rect from localToGlobal converts to canvas coords so the popup '
      'lands at the tapped char under non-100% scale', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final double scale in <double>[1.0, 1.5, 0.8]) {
      final GlobalKey charKey = GlobalKey();
      final GlobalKey pageKey = GlobalKey();
      late Rect canvasRect;
      late Size overlayScreen;

      await tester.pumpWidget(harness(
        scale: scale,
        home: Stack(
          key: pageKey,
          children: <Widget>[
            // 一个「字符」box，定位在画布 (300,200)。
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
      // 模拟 _globalRectOf：localToGlobal 报缩放后屏幕坐标。
      final RenderBox box =
          charKey.currentContext!.findRenderObject()! as RenderBox;
      final Rect rawScreenRect = globalRectOfBox(box);
      // 模拟 _lookupAt：换算回画布坐标系。
      canvasRect = scaledRectToCanvas(
        rawScreenRect,
        HibikiAppUiScale.of(pageContext),
      );
      // 模拟 _buildPopupOverlay：在根 Overlay 插入 Stack 承载定位浮层（与生产同构：
      // entry 根是 Stack，提供 StackParentData 给 Positioned）。
      final OverlayEntry entry = OverlayEntry(
        builder: (BuildContext c) => LayoutBuilder(
          builder: (BuildContext _, BoxConstraints cons) {
            overlayScreen = Size(cons.maxWidth, cons.maxHeight);
            final Rect pos = calcPopupPosition(
              selectionRect: canvasRect,
              screen: overlayScreen,
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
                  child: const ColoredBox(
                    key: ValueKey<String>('popup'),
                    color: Colors.red,
                  ),
                ),
              ],
            );
          },
        ),
      );
      Overlay.of(pageContext, rootOverlay: true).insert(entry);
      await tester.pumpAndSettle();

      // 浮层在根 Overlay 渲染出来。
      expect(find.byKey(const ValueKey<String>('popup')), findsOneWidget,
          reason: 'popup must render in the root overlay at scale $scale');

      // 换算后的 rect 与根 Overlay 的逻辑画布坐标系一致（char box 在画布 300,200）。
      expect(canvasRect.left, closeTo(300, 1.0),
          reason: 'canvasRect.left should match the char canvas x at $scale');
      expect(canvasRect.top, closeTo(200, 1.0),
          reason: 'canvasRect.top should match the char canvas y at $scale');

      // 浮层定位（calcPopupPosition）以画布坐标算出，应落在字符附近（下方贴合）。
      final Rect popupPos = calcPopupPosition(
        selectionRect: canvasRect,
        screen: overlayScreen,
        maxWidth: 360,
        maxHeight: 360,
      );
      // 字符底边在画布 y=250，浮层在其下方 4px 起（除非空间不足上翻）。
      expect(popupPos.top, greaterThanOrEqualTo(200),
          reason: 'popup must sit near the char (below it) at scale $scale');

      // 下一轮换新树前先摘除本轮 entry，避免跨轮叠加。
      entry.remove();
      entry.dispose();
      await tester.pump();
    }
  });

  testWidgets('without conversion the rect would be off by the scale factor',
      (tester) async {
    // 反证：直接拿 localToGlobal 的屏幕 rect 当画布 rect（旧 bug）会偏 factor s。
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final GlobalKey charKey = GlobalKey();
    late Rect rawScreenRect;
    await tester.pumpWidget(harness(
      scale: 1.5,
      home: Stack(
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
    rawScreenRect = globalRectOfBox(
        charKey.currentContext!.findRenderObject()! as RenderBox);
    // 屏幕坐标被放大了 1.5×：300→450。直接用它定位就会偏。
    expect(rawScreenRect.left, closeTo(450, 1.0));
    // 而换算后回到 300。
    expect(scaledRectToCanvas(rawScreenRect, 1.5).left, closeTo(300, 1.0));
  });
}
