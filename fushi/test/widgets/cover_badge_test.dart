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

  testWidgets('MD3：inverseSurface@0.85 半透明角标（2026-10-04 角标统一）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: false,
      child: const CoverBadge(icon: Icons.cloud_outlined),
    ));
    final Color color = _badgeColor(tester);
    final ColorScheme cs =
        Theme.of(tester.element(find.byType(CoverBadge))).colorScheme;
    expect(color, cs.inverseSurface.withValues(alpha: 0.85));
  });

  testWidgets('eink：纯黑实底（半透明黑在墨水屏合成抖动灰）', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const CoverBadge(icon: Icons.cloud_outlined),
    ));
    expect(_badgeColor(tester), Colors.black);
  });
}
