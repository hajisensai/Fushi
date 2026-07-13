import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// BUG-755 守卫：互联「手动填写令牌」折叠区里的 [HibikiTextField] 是带浮动标签的
/// OutlineInputBorder 字段。浮动标签会骑在字段顶边、上半部分溢出到字段上方；而
/// [ExpansionTile] 的展开体被 Flutter `Expansible` 包在 `ClipRect` 里，若
/// `childrenPadding` 顶部为 0，溢出的半个标签会被裁掉（「对端访问令牌」只剩下半截）。
///
/// 这两个用例用真实的 `ExpansionTile`（含 `Expansible` 的 `ClipRect`）复现裁剪 /
/// 验证修复：断言浮动标签 painted top 相对包住它的 `ClipRect` 顶沿的位置。
Future<double> _labelTopMinusClipTop(
  WidgetTester tester,
  EdgeInsetsGeometry childrenPadding,
) async {
  final TextEditingController controller = TextEditingController(
    text: 'mwr9S6dz5OQQrc4yWTXAHT2RKYLZ8Pl3KD3PWzDXAPw=',
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 500,
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: childrenPadding,
              title: const Text('手动填写令牌'),
              children: <Widget>[
                HibikiTextField(
                  controller: controller,
                  labelText: '对端访问令牌',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final Rect labelRect = tester.getRect(find.text('对端访问令牌'));
  // Expansible wraps the expanded body in ClipRect(child: Align(...)).
  final Finder clip = find
      .ancestor(of: find.text('对端访问令牌'), matching: find.byType(ClipRect))
      .first;
  final Rect clipRect = tester.getRect(clip);
  // > 0 => label sits below the clip top (fully visible).
  // < 0 => label top is above the clip top (top half clipped away).
  return labelRect.top - clipRect.top;
}

void main() {
  testWidgets(
      'BUG-755 repro: zero childrenPadding clips the floating label top half',
      (WidgetTester tester) async {
    final double delta = await _labelTopMinusClipTop(tester, EdgeInsets.zero);
    expect(
      delta < 0,
      isTrue,
      reason:
          'floating label top ($delta) should be above the Expansible ClipRect '
          'top when childrenPadding is zero (this is the clipped state)',
    );
  });

  testWidgets(
      'BUG-755 fix: top childrenPadding keeps the floating label inside clip',
      (WidgetTester tester) async {
    // Must match the value used in interconnect.part.dart.
    final double delta =
        await _labelTopMinusClipTop(tester, const EdgeInsets.only(top: 10));
    expect(
      delta >= 0,
      isTrue,
      reason:
          'floating label top ($delta) must sit within the Expansible ClipRect '
          '(fully visible) once top childrenPadding is applied',
    );
  });
}
