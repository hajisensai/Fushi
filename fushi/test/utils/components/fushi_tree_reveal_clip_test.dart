import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_tree.dart';

/// 牌组色块里的内层行悬停会轻微放大（FushiHoverLift）。[FushiTreeReveal] 若在展开
/// 静止时也裁切，放大的行左右会被切成平边；只在高度动画途中裁切。
void main() {
  Widget host({required bool visible}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          child: FushiTreeReveal(
            visible: visible,
            child: const SizedBox(height: 40),
          ),
        ),
      ),
    ),
  );

  Clip clipOf(WidgetTester tester) => tester
      .widget<ClipRect>(
        find.descendant(
          of: find.byType(FushiTreeReveal),
          matching: find.byType(ClipRect),
        ),
      )
      .clipBehavior;

  testWidgets('展开静止时不裁切，高度动画途中裁切', (WidgetTester tester) async {
    await tester.pumpWidget(host(visible: true));
    expect(clipOf(tester), Clip.none, reason: '展开静止：行内悬停放大不被切');

    await tester.pumpWidget(host(visible: false));
    await tester.pump(const Duration(milliseconds: 16));
    expect(clipOf(tester), Clip.hardEdge, reason: '收起途中按高度裁切');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(FushiTreeReveal),
        matching: find.byType(ClipRect),
      ),
      findsNothing,
      reason: '收起落定后整段不画',
    );

    await tester.pumpWidget(host(visible: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(clipOf(tester), Clip.hardEdge, reason: '展开途中按高度裁切');
    await tester.pumpAndSettle();
    expect(clipOf(tester), Clip.none, reason: '弹簧落定精确到 1 后不再裁切');
    expect(tester.getSize(find.byType(FushiTreeReveal)).height, 40);
  });
}
