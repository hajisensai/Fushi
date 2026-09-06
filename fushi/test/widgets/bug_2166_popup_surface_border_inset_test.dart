import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-2166 守卫：查词浮层的描边必须**看得见**。
///
/// BUG-1692 把 [FushiPopupSurface] 的描边从 `foregroundPainter` 挪到子节点**之前**
/// 绘制（macOS 上排在平台视图之后的 Flutter 绘制会让整块 WebView 收不到鼠标）。代价
/// 是：铺满 surface 的**不透明**子节点会把描边整条盖掉。查词浮层正是这种情况——
/// WebView 铺满顶栏以下的全部区域、文档背景不透明，于是四边描边只剩顶栏那一小段，
/// 加上圆角弧被 `Clip.antiAlias` 裁出 WebView 的那几段，用户看到的就是「查词框没包边」。
///
/// 修法不是把描边挪回 foreground（那会让 BUG-1692 回归），而是**给描边让位**：
/// `borderOnForeground: false` 时子节点沿四边内缩一个笔宽、并按内圈半径再裁一次，
/// 描边环因此永远落在子节点之外。本守卫钉住这个内缩。
void main() {
  const double borderWidth = 1;
  const Size boxSize = Size(200, 120);
  const Key childKey = ValueKey<String>('popup-surface-child');

  Widget subject({
    required bool borderOnForeground,
    bool showBorder = true,
  }) {
    return MaterialApp(
      home: Center(
        child: SizedBox(
          width: boxSize.width,
          height: boxSize.height,
          child: FushiPopupSurface(
            showBorder: showBorder,
            borderOnForeground: borderOnForeground,
            child: const SizedBox.expand(key: childKey),
          ),
        ),
      ),
    );
  }

  testWidgets('borderOnForeground: false —— 子节点让出描边那一圈（BUG-2166）',
      (WidgetTester tester) async {
    await tester.pumpWidget(subject(borderOnForeground: false));

    expect(
      tester.getSize(find.byKey(childKey)),
      Size(boxSize.width - 2 * borderWidth, boxSize.height - 2 * borderWidth),
      reason: '子节点没内缩 ⇒ 铺满 surface 的不透明 WebView 把描边直边段整条盖住，'
          '只在圆角处漏出几段弧 ⇒「查词框没包边」（BUG-2166 回归）',
    );

    final Iterable<ClipRRect> clips = tester.widgetList<ClipRRect>(
      find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(
      clips.any(
        (ClipRRect clip) =>
            clip.borderRadius ==
            BorderRadius.circular(FushiRadii.cardValue - borderWidth),
      ),
      isTrue,
      reason: '内缩后必须按内圈半径再裁一次，否则子节点的直角仍会盖住圆角处的描边弧',
    );
  });

  testWidgets('borderOnForeground 默认 true —— 纯 Flutter 子树不内缩，观感不变',
      (WidgetTester tester) async {
    await tester.pumpWidget(subject(borderOnForeground: true));

    expect(
      tester.getSize(find.byKey(childKey)),
      boxSize,
      reason: '描边画在子节点之后时本就盖得住，无须让位；内缩会白白改掉既有布局',
    );
  });

  testWidgets('showBorder: false —— 无描边可让，不内缩', (WidgetTester tester) async {
    await tester.pumpWidget(
      subject(borderOnForeground: false, showBorder: false),
    );

    expect(tester.getSize(find.byKey(childKey)), boxSize);
  });

  testWidgets('描边笔宽与内缩量同源（都是 1）', (WidgetTester tester) async {
    await tester.pumpWidget(subject(borderOnForeground: false));

    final Material material = tester.widget<Material>(
      find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(Material),
      ),
    );
    final RoundedRectangleBorder shape =
        material.shape! as RoundedRectangleBorder;
    expect(
      shape.side.width,
      borderWidth,
      reason: '笔宽与内缩量脱钩 ⇒ 描边要么被盖回去、要么多出一条空隙',
    );
    expect(shape.side.strokeAlign, BorderSide.strokeAlignInside,
        reason: '描边不再画在 shape 内侧时，内缩一个笔宽就避让不干净了');
  });
}
