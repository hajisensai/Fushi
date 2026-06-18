import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    testWidgets('mobile + controller shows a one-tap paste button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.content_paste_outlined), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing,
          reason: 'mobile uses the system IME, not the on-screen keyboard');
    });

    testWidgets('desktop shows the keyboard button, not paste',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
      expect(find.byIcon(Icons.content_paste_outlined), findsNothing);
    });

    testWidgets(
        'mobile paste button inserts clipboard text and fires onChanged',
        (WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'hi'}
            : null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final TextEditingController c = TextEditingController(text: 'a');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      final List<String> changes = <String>[];
      await tester.pumpWidget(buildTestApp(
        HibikiTextField(controller: c, onChanged: changes.add),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_paste_outlined));
      await tester.pumpAndSettle();
      expect(c.text, 'ahi');
      expect(changes.last, 'ahi');
    });

    testWidgets('mobile no-controller shows no paste button',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTextField(initialValue: 'x'),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.content_paste_outlined), findsNothing);
    });
  });

  group('search fields on-screen keyboard affordance', () {
    testWidgets('desktop HibikiSearchField shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        HibikiSearchField(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    });

    testWidgets('optional clear button clears text and keeps search focus',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController(text: 'term');
      final FocusNode focusNode = FocusNode();
      final List<String> clears = <String>[];
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        HibikiSearchField(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          clearButtonKey: const ValueKey<String>('search-clear'),
          onChanged: (_) {},
          onClear: () {
            c.clear();
            clears.add(c.text);
          },
          onSubmitted: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();

      expect(
          find.byKey(const ValueKey<String>('search-clear')), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('search-clear')));
      await tester.pump();

      expect(c.text, isEmpty);
      expect(clears, <String>['']);
      expect(focusNode.hasFocus, isTrue);
      expect(find.byKey(const ValueKey<String>('search-clear')), findsNothing);
      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    });

    testWidgets('desktop compact search row shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        HibikiCompactSearchRow(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          onSubmit: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    });
  });

  testWidgets('desktop HibikiEditorPanel shows the ⌨ button',
      (WidgetTester tester) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);

    await tester.pumpWidget(buildTestApp(
      SizedBox(
        width: 480,
        height: 320,
        child: HibikiEditorPanel(controller: c),
      ),
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
  });
}
