import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('pill selected shape renders a rounded inset highlight',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      HibikiListItem(
        title: const Text('基础'),
        selected: true,
        selectedShape: HibikiListItemSelectedShape.pill,
        onTap: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final BoxDecoration decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, isNotNull);
    expect(decoration.color, isNotNull);
    expect(container.margin, isNot(EdgeInsets.zero));

    final InkWell ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(ink.borderRadius, isNotNull);
  });

  testWidgets('default fill shape keeps square full-bleed highlight',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      HibikiListItem(
        title: const Text('基础'),
        selected: true,
        onTap: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    // fill 路径：AnimatedContainer 把 color: 规范化为无圆角 BoxDecoration，
    // 故 borderRadius 必须为 null（方角满宽），且无内缩 margin（golden 不变）。
    final BoxDecoration decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, isNull);
    expect(container.margin, EdgeInsets.zero);
  });
}
