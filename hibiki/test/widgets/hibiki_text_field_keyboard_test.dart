import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiTextField on-screen keyboard affordance', () {
    testWidgets('desktop + controller shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget,
          reason: 'desktop gamepad users need an on-screen keyboard');
    });

    testWidgets('mobile does NOT show the ⌨ (system IME is available)',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
    });

    testWidgets('a caller-supplied suffix is never overridden',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c, suffixIcon: const Icon(Icons.clear)),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });

    testWidgets(
        'no controller (initialValue) shows no ⌨ (nothing to type into)',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTextField(initialValue: 'x'),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
    });
  });
}
