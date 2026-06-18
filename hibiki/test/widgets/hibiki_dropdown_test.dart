import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_dropdown.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiDropdown', () {
    testWidgets('shows initial option label', (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['Apple', 'Banana', 'Cherry'],
          initialOption: 'Banana',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      expect(find.byType(DropdownMenu<String>), findsOneWidget);
      expect(find.text('Banana'), findsOneWidget);
    });

    testWidgets('calls onChanged when new option selected', (tester) async {
      String? selected;
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['A', 'B'],
          initialOption: 'A',
          generateLabel: (v) => v,
          onChanged: (v) => selected = v,
        ),
      ));

      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();

      expect(selected, 'B');
    });

    testWidgets('disabled dropdown does not call onChanged', (tester) async {
      bool changed = false;
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['X', 'Y'],
          initialOption: 'X',
          generateLabel: (v) => v,
          onChanged: (_) => changed = true,
          enabled: false,
        ),
      ));

      final DropdownMenu<String> dropdown =
          tester.widget(find.byType(DropdownMenu<String>));
      expect(dropdown.enabled, isFalse);
      expect(changed, isFalse);
    });

    testWidgets('deduplicates options via toSet', (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['A', 'A', 'B'],
          initialOption: 'A',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();

      expect(find.text('A'), findsNWidgets(2));
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('falls back to first option when initial not in list',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['X', 'Y'],
          initialOption: 'Z',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      expect(find.text('X'), findsOneWidget);
    });
  });

  group('HibikiDropdown platform routing', () {
    // Every polled platform (Windows/Linux/iOS/macOS) must use the
    // gamepad-enterable MenuAnchor; only Android — whose engine delivers real
    // key events — keeps the stock DropdownMenu. Guards the unification so a
    // gamepad can enter the menu on iOS/macOS, not just on desktop.
    Widget dropdownOn(TargetPlatform platform) {
      return buildTestApp(
        HibikiDropdown<String>(
          options: const ['A', 'B'],
          initialOption: 'A',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
        theme: ThemeData.light(useMaterial3: true).copyWith(platform: platform),
      );
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('uses MenuAnchor (not stock DropdownMenu) on $platform',
          (tester) async {
        await tester.pumpWidget(dropdownOn(platform));

        // The bare MenuAnchor path renders no DropdownMenu at all.
        expect(find.byType(DropdownMenu<String>), findsNothing);
        expect(find.byType(MenuAnchor), findsOneWidget);
      });
    }

    testWidgets('keeps the stock DropdownMenu on Android (engine key events)',
        (tester) async {
      await tester.pumpWidget(dropdownOn(TargetPlatform.android));

      // DropdownMenu is itself built on a MenuAnchor internally, so the
      // presence of the stock DropdownMenu — not the MenuAnchor count — is the
      // signal that Android keeps the engine-key-event path.
      expect(find.byType(DropdownMenu<String>), findsOneWidget);
    });

    testWidgets('MenuAnchor long labels can wrap in trigger and menu',
        (tester) async {
      const String longLabel = 'Fit keep ratio add black bars';
      await tester.pumpWidget(
        buildTestApp(
          Center(
            child: SizedBox(
              width: 240,
              child: HibikiDropdown<String>(
                options: const <String>[longLabel, 'Stretch'],
                initialOption: longLabel,
                generateLabel: (String v) => v,
                onChanged: (_) {},
              ),
            ),
          ),
          theme: ThemeData.light(useMaterial3: true).copyWith(
            platform: TargetPlatform.windows,
          ),
        ),
      );

      Text selected = tester.widget<Text>(find.text(longLabel));
      expect(selected.maxLines, 2);
      expect(selected.softWrap, isTrue);

      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      final Iterable<Text> longTexts =
          tester.widgetList<Text>(find.text(longLabel));
      expect(longTexts, hasLength(2));
      for (final Text text in longTexts) {
        expect(text.maxLines, 2);
        expect(text.softWrap, isTrue);
      }
    });

    testWidgets(
        'Android stock DropdownMenu caps menuHeight to the screen '
        '(no off-screen overflow with many options)', (tester) async {
      final List<String> many =
          List<String>.generate(40, (int i) => 'Option $i');
      await tester.pumpWidget(
        buildTestApp(
          HibikiDropdown<String>(
            options: many,
            initialOption: 'Option 0',
            generateLabel: (String v) => v,
            onChanged: (_) {},
          ),
          theme: ThemeData.light(useMaterial3: true)
              .copyWith(platform: TargetPlatform.android),
        ),
      );

      final DropdownMenu<String> dropdown =
          tester.widget(find.byType(DropdownMenu<String>));
      final double screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      // A bounded menu means the 40-item list scrolls WITHIN the screen instead
      // of running its bottom entries off the bottom edge.
      expect(dropdown.menuHeight, isNotNull);
      expect(dropdown.menuHeight, lessThanOrEqualTo(screenHeight));
    });

    testWidgets('MenuAnchor trigger registers with the focus root',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiDropdown<String>(
            focusId: const HibikiFocusId('fruit-dropdown'),
            options: const ['A', 'B'],
            initialOption: 'A',
            generateLabel: (v) => v,
            onChanged: (_) {},
          ),
        ),
        theme: ThemeData.light(useMaterial3: true).copyWith(
          platform: TargetPlatform.windows,
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('A')),
      );

      expect(
        controller.requestById(const HibikiFocusId('fruit-dropdown')),
        isTrue,
      );
      await tester.pump();
      expect(controller.activeId, const HibikiFocusId('fruit-dropdown'));

      expect(find.byType(MenuItemButton), findsNothing);
      Actions.maybeInvoke<ActivateIntent>(
        controller.activeContext!,
        const ActivateIntent(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNWidgets(2));
    });
  });
}
