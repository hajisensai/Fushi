import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';

Widget _app({required bool eink, required Widget child}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

Color _badgeColor(WidgetTester tester) {
  final Container container = tester.widget<Container>(
    find.descendant(
      of: find.byType(CoverBadge),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!;
}

void main() {
  testWidgets('渲染图标 + 可选文字', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: false,
      child: const CoverBadge(icon: Icons.subtitles_outlined, label: '12'),
    ));
    expect(find.byIcon(Icons.subtitles_outlined), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('常规主题：半透明深色胶囊（固定 scrim，不随 colorScheme）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: false,
      child: const CoverBadge(icon: Icons.cloud_outlined),
    ));
    final Color color = _badgeColor(tester);
    expect(color.a, lessThan(1.0));
    expect(color.r, 0);
  });

  testWidgets('eink：纯黑实底（半透明黑在墨水屏合成抖动灰）', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const CoverBadge(icon: Icons.cloud_outlined),
    ));
    expect(_badgeColor(tester), Colors.black);
  });
}
