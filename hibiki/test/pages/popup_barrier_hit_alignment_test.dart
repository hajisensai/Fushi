import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

import '../widgets/widget_test_helpers.dart';

/// TODO-805：点查词弹窗外的「关闭命中区」必须与弹窗**实际可视矩形**对齐。
///
/// 生产里弹窗层 [DictionaryPopupLayer] 与一个全屏 dismiss barrier
/// （`Positioned.fill` 的 `GestureDetector(onTap: clearDictionaryResult)`，
/// TODO-834 后点真空白清整栈）同处一个 `Stack`，弹窗在 barrier 之上。点弹窗内应
/// 被弹窗吃掉、点弹窗外才落到 barrier（命中区几何不受 TODO-834 关闭语义改动影响）。
///
/// 根因：弹窗 surface（[HibikiPopupSurface] = `Material`）本身不吸收指针；只有
/// 内部 WebView 正文区与按钮命中真值。带顶栏（音频控制 / X / 返回）时，顶栏的
/// **空白区**、surface 的边框/圆角余白都不吸收点击 → 落到下面的 barrier → 关窗。
/// 用户因此感到「点击消失的位置和弹窗外边有差异」：明明点在弹窗可视范围内（顶栏
/// 空白处）却把窗关了。
///
/// 这里复刻生产 Stack：barrier 在下、弹窗在上，弹窗带顶栏（headerWidget + X）。
/// 在弹窗矩形内的顶栏空白区点击，断言 barrier 的 onTap **不**触发——即关闭命中区
/// 不越过弹窗可视边界。
void main() {
  Widget buildBarrierAndPopup({
    required Rect popupRect,
    required Size screen,
    required VoidCallback onBarrierTap,
    Widget? headerWidget,
    VoidCallback? onClose,
  }) {
    return buildTestApp(
      SizedBox(
        width: screen.width,
        height: screen.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 全屏 dismiss barrier（生产 base_source_page.buildDictionary 的那层）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onBarrierTap,
                child: Container(color: Colors.transparent),
              ),
            ),
            // 弹窗层（生产经 parkedPopupLayer 的 Positioned 摆放）。
            Positioned(
              left: popupRect.left,
              top: popupRect.top,
              width: popupRect.width,
              height: popupRect.height,
              child: DictionaryPopupLayer(
                result: null,
                isSearching: false,
                webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
                // 顶栏存在（headerWidget / onClose），复刻 reader/video 顶层弹窗。
                headerWidget: headerWidget,
                onClose: onClose,
                // 桌面默认禁用滑动关闭，避免 SwipeDismissWrapper 干扰命中。
                enableSwipeToClose: false,
                onDismiss: () {},
                onTextSelected: (text, rect) {},
                onLinkClick: (query, rect) {},
                onMineEntry: (fields) async => const MinePopupResult(),
                onDuplicateCheck: (expression, reading) async => false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets(
      'tapping inside the popup header blank area does NOT hit the dismiss '
      'barrier (close region == visible popup rect)', (tester) async {
    const Size screen = Size(800, 600);
    // 弹窗矩形：左上 (200,150)，宽 360 高 360（顶栏 40px 在最上）。
    const Rect popupRect = Rect.fromLTWH(200, 150, 360, 360);
    int barrierTaps = 0;

    await tester.pumpWidget(buildBarrierAndPopup(
      popupRect: popupRect,
      screen: screen,
      onBarrierTap: () => barrierTaps++,
      // 顶栏放一个有左右空白的 header（音频控制条的简化版）。
      headerWidget: const SizedBox(height: 40, width: 360),
      onClose: () {},
    ));
    await tester.pump();

    // 点在弹窗矩形内、但落在顶栏空白区（避开右端 X 按钮，取顶栏中线靠左）。
    final Offset headerBlank = Offset(
      popupRect.left + 60, // 顶栏左侧空白
      popupRect.top + 20, // 顶栏垂直中线（40px 顶栏内）
    );
    await tester.tapAt(headerBlank);
    await tester.pump();

    expect(barrierTaps, 0, reason: '点在弹窗顶栏空白区（弹窗可视范围内）不得触发外部关闭 barrier');
  });

  testWidgets(
      'tapping just outside the popup edge DOES hit the dismiss barrier',
      (tester) async {
    const Size screen = Size(800, 600);
    const Rect popupRect = Rect.fromLTWH(200, 150, 360, 360);
    int barrierTaps = 0;

    await tester.pumpWidget(buildBarrierAndPopup(
      popupRect: popupRect,
      screen: screen,
      onBarrierTap: () => barrierTaps++,
      headerWidget: const SizedBox(height: 40, width: 360),
      onClose: () {},
    ));
    await tester.pump();

    // 点在弹窗左侧外 8px（弹窗可视范围外）。
    final Offset outside = Offset(popupRect.left - 8, popupRect.top + 40);
    await tester.tapAt(outside);
    await tester.pump();

    expect(barrierTaps, 1, reason: '点弹窗可视范围外应触发关闭 barrier');
  });

  testWidgets(
      'tapping the popup body region (no header) does NOT hit the barrier',
      (tester) async {
    const Size screen = Size(800, 600);
    const Rect popupRect = Rect.fromLTWH(200, 150, 360, 360);
    int barrierTaps = 0;

    // 无顶栏的层（如纯查词嵌套返回层）：正文区也必须吸收点击。
    await tester.pumpWidget(buildBarrierAndPopup(
      popupRect: popupRect,
      screen: screen,
      onBarrierTap: () => barrierTaps++,
    ));
    await tester.pump();

    // 点在弹窗正中（无顶栏时 body 占满，WebView 单测起不来，故靠 surface 吸收）。
    await tester.tapAt(popupRect.center);
    await tester.pump();

    expect(barrierTaps, 0, reason: '点弹窗正文区（弹窗可视范围内）不得触发关闭 barrier');
  });

  testWidgets(
      'tapping a rounded corner inside the popup rect does NOT hit the barrier '
      '(TODO-805 regression: close region == full visible popup rect)',
      (tester) async {
    const Size screen = Size(800, 600);
    const Rect popupRect = Rect.fromLTWH(200, 150, 360, 360);
    int barrierTaps = 0;

    await tester.pumpWidget(buildBarrierAndPopup(
      popupRect: popupRect,
      screen: screen,
      onBarrierTap: () => barrierTaps++,
      headerWidget: const SizedBox(height: 40, width: 360),
      onClose: () {},
    ));
    await tester.pump();

    // 弹窗左上角内 2px：在 Positioned 矩形内、但在 12px 圆角弧之外。修复前
    // RenderPhysicalShape 按圆角裁剪命中 → 漏到 barrier 关窗；修复后整个矩形吸收。
    await tester.tapAt(Offset(popupRect.left + 2, popupRect.top + 2));
    await tester.pump();

    expect(barrierTaps, 0, reason: '圆角余白仍在弹窗可视矩形内，点击不得漏到外部关闭 barrier');
  });
}
