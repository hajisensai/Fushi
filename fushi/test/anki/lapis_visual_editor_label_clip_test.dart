// 「布局」折叠区里第一个下拉框的浮动标签不能被 [ExpansionTile] 的 ClipRect 裁掉。
//
// Material 的 outline 输入框把浮动 label 画在自身 RenderBox **上方**（label 竖直
// 居中压在顶边框线上，约半个字高露在框外）；[ExpansionTile] 又用 ClipRect +
// Align(heightFactor) 做展开动画，裁剪线正压在第一个子控件的顶边。两者叠在一起，
// 折叠区里第一个下拉框的标签就被削掉上半截（BUG-1677）。
//
// 这类几何断言不能只 `findsOneWidget`——被裁的标签照样 find 得到。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

import 'lapis_style_editor_harness.dart';

/// [inner] 顶部越过它**最近的裁剪祖先**上边界的高度；>0 = 被裁掉这么多。
double _topOverflowIntoClip(WidgetTester tester, Finder inner) {
  final Finder clip =
      find.ancestor(of: inner, matching: find.byType(ClipRect)).first;
  return tester.getRect(clip).top - tester.getRect(inner).top;
}

void main() {
  testWidgets('布局折叠区第一个下拉框的标签完整可见，没被展开动画的 ClipRect 裁掉',
      (WidgetTester tester) async {
    useWideWindow(tester);
    await pumpEditor(tester, initialCustomCss: '');

    await tester.tap(find.text(t.anki_lapis_visual_layout));
    await tester.pumpAndSettle();

    // 下拉框有 initialSelection（「默认」），label 一开始就是浮起状态。
    final Finder label = find.text(t.anki_lapis_visual_layout_sentence);
    expect(label, findsOneWidget);

    // 修复前实测溢出 5.5px（= 标签高 16 × 浮动缩放 0.75 ÷ 2 − 边框 1 ÷ 2）。
    final double overflow = _topOverflowIntoClip(tester, label);
    expect(
      overflow,
      lessThanOrEqualTo(0.0),
      reason: '「例句位置」标签有 ${overflow}px 露在裁剪线之外，会被削掉上半截',
    );
  });
}
