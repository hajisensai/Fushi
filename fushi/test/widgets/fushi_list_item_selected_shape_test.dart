import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiM3eShape, kFushiMd3RowInset, kFushiMd3RowRadius;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('pill selected shape renders a rounded inset highlight',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      FushiListItem(
        title: const Text('基础'),
        selected: true,
        selectedShape: FushiListItemSelectedShape.pill,
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

  testWidgets('default fill shape uses a narrower rounded inset highlight',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      FushiListItem(
        title: const Text('基础'),
        selected: true,
        onTap: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    // fill 路径（2026-10-04 卡片 / 列表统一）：MD3 状态层与选中底是内缩的圆角
    // 块，只内缩 4（pill 内缩 8），不再顶到容器边。M3E（2026-10-05）：选中行
    // 形变到 corner-large 16，未选中 / 悬停仍是 12（kFushiMd3RowRadius）。
    final BoxDecoration decoration = container.decoration! as BoxDecoration;
    expect(
      decoration.borderRadius,
      const BorderRadius.all(Radius.circular(FushiM3eShape.listActive)),
    );
    expect(kFushiMd3RowRadius, 12);
    expect(
      container.margin,
      const EdgeInsets.symmetric(horizontal: kFushiMd3RowInset),
    );
  });
}
