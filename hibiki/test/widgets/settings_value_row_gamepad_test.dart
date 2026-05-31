import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

void main() {
  group('Stepper row gamepad adjust', () {
    testWidgets(
        'D-pad right/left adjusts the value in place and does NOT move focus',
        (WidgetTester tester) async {
      double value = 10;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: StatefulBuilder(
            builder: (BuildContext c, StateSetter setState) =>
                AdaptiveSettingsStepperRow(
              title: 'Font',
              value: value,
              step: 1,
              min: 0,
              max: 64,
              format: (double v) => '${v.round()}',
              onChanged: (double v) => setState(() => value = v),
            ),
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Font')),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'the stepper row registers as a focus target');
      final HibikiFocusId? activeBefore = controller.activeId;
      final BuildContext ctx = controller.activeContext!;

      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          ctx,
          const GamepadButtonIntent(GamepadButton.dpadRight),
        ),
        isTrue,
        reason:
            'D-pad right is consumed by the value row (does not move focus)',
      );
      await tester.pump();
      expect(value, 11);
      expect(controller.activeId, activeBefore,
          reason: 'adjusting value must not move focus to another row');

      Actions.maybeInvoke<GamepadButtonIntent>(
        ctx,
        const GamepadButtonIntent(GamepadButton.dpadLeft),
      );
      await tester.pump();
      expect(value, 10);
    });

    testWidgets('D-pad up/down is NOT consumed (lets focus move between rows)',
        (WidgetTester tester) async {
      double value = 10;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: AdaptiveSettingsStepperRow(
            title: 'Font',
            value: value,
            step: 1,
            min: 0,
            max: 64,
            format: (double v) => '${v.round()}',
            onChanged: (double v) => value = v,
          ),
        ),
      ));
      await tester.pump();
      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Font')),
      );
      controller.ensureFocus();
      await tester.pump();

      // Up/Down must return null/false from the row's GamepadButtonIntent so the
      // GamepadService falls through to directional focus traversal.
      final Object? upResult = Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadUp),
      );
      expect(upResult, isNot(true),
          reason: 'up/down must not be consumed by the value row');
      expect(value, 10, reason: 'up/down does not change the value');
    });

    testWidgets('D-pad right at max stays consumed and clamped (no overshoot)',
        (WidgetTester tester) async {
      double value = 64;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: StatefulBuilder(
            builder: (BuildContext c, StateSetter setState) =>
                AdaptiveSettingsStepperRow(
              title: 'Font',
              value: value,
              step: 1,
              min: 0,
              max: 64,
              format: (double v) => '${v.round()}',
              onChanged: (double v) => setState(() => value = v),
            ),
          ),
        ),
      ));
      await tester.pump();
      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Font')),
      );
      controller.ensureFocus();
      await tester.pump();

      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          controller.activeContext!,
          const GamepadButtonIntent(GamepadButton.dpadRight),
        ),
        isTrue,
        reason: 'at max the press is still consumed (stays on the row)',
      );
      await tester.pump();
      expect(value, 64, reason: 'clamped at max, no overshoot');
    });
  });

  group('Slider row gamepad adjust', () {
    testWidgets('D-pad right/left adjusts a slider row by one division step',
        (WidgetTester tester) async {
      double value = 0.5;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: StatefulBuilder(
            builder: (BuildContext c, StateSetter setState) =>
                AdaptiveSettingsSliderRow(
              title: 'Volume',
              value: value,
              divisions: 10,
              onChanged: (double v) => setState(() => value = v),
            ),
          ),
        ),
      ));
      await tester.pump();
      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Volume')),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'the slider row registers as a focus target');
      final BuildContext ctx = controller.activeContext!;

      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          ctx,
          const GamepadButtonIntent(GamepadButton.dpadRight),
        ),
        isTrue,
      );
      await tester.pump();
      expect(value, closeTo(0.6, 0.0001),
          reason: 'one division step of (max-min)/divisions = 0.1');

      Actions.maybeInvoke<GamepadButtonIntent>(
        ctx,
        const GamepadButtonIntent(GamepadButton.dpadLeft),
      );
      await tester.pump();
      expect(value, closeTo(0.5, 0.0001));
    });
  });

  group('gamepadSeekableSlider (bare seek bar)', () {
    testWidgets('D-pad right/left seeks by the explicit step (±5s)',
        (WidgetTester tester) async {
      double value = 30000; // 30s into a 2-min clip
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: StatefulBuilder(
            builder: (BuildContext c, StateSetter setState) =>
                gamepadSeekableSlider(
              value: value,
              max: 120000,
              step: 5000,
              onChanged: (double v) => setState(() => value = v),
            ),
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byType(Slider)),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'a bare seek bar is a focus target too');
      final BuildContext ctx = controller.activeContext!;

      Actions.maybeInvoke<GamepadButtonIntent>(
        ctx,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      );
      await tester.pump();
      expect(value, 35000, reason: 'D-pad right seeks +5s');

      Actions.maybeInvoke<GamepadButtonIntent>(
        ctx,
        const GamepadButtonIntent(GamepadButton.dpadLeft),
      );
      await tester.pump();
      expect(value, 30000, reason: 'D-pad left seeks -5s');
    });
  });

  group('value row does not swallow page buttons (review W2)', () {
    testWidgets(
        'Y / LT / RT / dpadUp are NOT consumed by a focused value row '
        '(they bubble to the page so tab-switch / focus-search still work)',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: AdaptiveSettingsStepperRow(
            title: 'Font',
            value: 10,
            step: 1,
            min: 0,
            max: 64,
            format: (double v) => '${v.round()}',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();
      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Font')),
      );
      controller.ensureFocus();
      await tester.pump();
      final BuildContext ctx = controller.activeContext!;

      for (final GamepadButton b in <GamepadButton>[
        GamepadButton.y,
        GamepadButton.lt,
        GamepadButton.rt,
        GamepadButton.dpadUp,
      ]) {
        expect(
          Actions.maybeInvoke<GamepadButtonIntent>(ctx, GamepadButtonIntent(b)),
          isNot(true),
          reason: '$b must bubble past the value row to the page',
        );
      }
    });
  });
}
