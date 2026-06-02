import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

// Reproduction harness for the desktop keyboard-focus bugs:
//   1. Arrow keys (up/down/left/right) must adjust a focused number stepper.
//   2. Tab traversal must scroll the newly-focused widget into view
//      (Flutter's default ensureVisible) inside the dialog-style scroll chain
//      (ConstrainedBox -> SingleChildScrollView -> Column).

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      home: Scaffold(body: child),
    );

Rect _globalRect(Finder finder, WidgetTester tester) {
  final RenderBox box = tester.renderObject<RenderBox>(finder);
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  testWidgets('focused number stepper increments on ArrowRight/ArrowUp', (
    tester,
  ) async {
    double value = 10;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => AdaptiveSettingsStepperRow(
            title: 'Font size',
            value: value,
            step: 1,
            min: 0,
            max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );

    // Move focus onto the stepper (first Tab lands on its control).
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final double before = value;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(value, greaterThan(before),
        reason: 'ArrowRight/ArrowUp should increase the stepper value');
  });

  testWidgets('focused number stepper decrements on ArrowLeft/ArrowDown', (
    tester,
  ) async {
    double value = 10;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => AdaptiveSettingsStepperRow(
            title: 'Font size',
            value: value,
            step: 1,
            min: 0,
            max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final double before = value;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(value, lessThan(before),
        reason: 'ArrowLeft/ArrowDown should decrease the stepper value');
  });

  testWidgets('Tab traversal scrolls a below-the-fold control into view', (
    tester,
  ) async {
    // Mirror the desktop dialog scroll chain.
    await tester.pumpWidget(
      _app(
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
            child: SingleChildScrollView(
              child: Column(
                children: List<Widget>.generate(
                  20,
                  (i) => SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: () {},
                      child: Text('Button $i'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final Rect viewport =
        _globalRect(find.byType(SingleChildScrollView), tester);

    // Tab several times so focus must move past the visible fold.
    for (int i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }

    final FocusNode? focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    final BuildContext? ctx = focused!.context;
    expect(ctx, isNotNull);
    final RenderBox box = ctx!.findRenderObject()! as RenderBox;
    final Rect focusRect = box.localToGlobal(Offset.zero) & box.size;

    // The focused control must be inside the scroll viewport (visible).
    expect(
      viewport.top <= focusRect.top + 1 &&
          focusRect.bottom <= viewport.bottom + 1,
      isTrue,
      reason:
          'Focused control rect $focusRect should be within viewport $viewport',
    );
  });

  testWidgets(
      'Tab into a below-fold stepper scrolls it into view (dialog '
      'nesting: ModalSheetFrame scrollable + AnimatedSize + Column)', (
    tester,
  ) async {
    // Reproduce the desktop reader appearance dialog scroll chain.
    final List<double> values = List<double>.filled(20, 10);
    await tester.pumpWidget(
      _app(
        Center(
          child: ConstrainedBox(
            // HibikiDialogFrame(scrollable: false) outer constraint
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 420),
            child: HibikiModalSheetFrame(
              maxHeightFactor: 0.8,
              scrollable: true,
              body: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: StatefulBuilder(
                  builder: (context, setState) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < values.length; i++)
                        AdaptiveSettingsStepperRow(
                          title: 'Row $i',
                          value: values[i],
                          step: 1,
                          min: 0,
                          max: 64,
                          format: (v) => '${v.round()}',
                          onChanged: (v) => setState(() => values[i] = v),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final Rect viewport =
        _globalRect(find.byType(SingleChildScrollView), tester);

    for (int i = 0; i < 14; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final FocusNode focused = FocusManager.instance.primaryFocus!;
    final RenderBox box = focused.context!.findRenderObject()! as RenderBox;
    final Rect focusRect = box.localToGlobal(Offset.zero) & box.size;

    expect(
      viewport.top <= focusRect.top + 1 &&
          focusRect.bottom <= viewport.bottom + 1,
      isTrue,
      reason: 'Focused stepper $focusRect should be within viewport $viewport',
    );
  });

  testWidgets('stepper is a SINGLE focus stop between other controls', (
    tester,
  ) async {
    double value = 10;
    final FocusNode before = FocusNode(debugLabel: 'before');
    final FocusNode after = FocusNode(debugLabel: 'after');
    addTearDown(before.dispose);
    addTearDown(after.dispose);

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: <Widget>[
              TextButton(
                focusNode: before,
                onPressed: () {},
                child: const Text('before'),
              ),
              AdaptiveSettingsStepperRow(
                title: 'Font size',
                value: value,
                step: 1,
                min: 0,
                max: 64,
                format: (v) => '${v.round()}',
                onChanged: (v) => setState(() => value = v),
              ),
              TextButton(
                focusNode: after,
                onPressed: () {},
                child: const Text('after'),
              ),
            ],
          ),
        ),
      ),
    );

    // Tab 1 -> before, Tab 2 -> the stepper (one stop), Tab 3 -> after.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(before.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // The stepper now holds focus: Left/Right adjust value, and it is NOT one of
    // the neighbouring buttons (proves the +/- buttons are not separate stops).
    // (Up/Down are reserved for row-to-row navigation, so the probe is Right.)
    expect(before.hasPrimaryFocus, isFalse);
    expect(after.hasPrimaryFocus, isFalse);
    final double mid = value;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, greaterThan(mid),
        reason: 'the single focus stop between the buttons is the stepper');

    // One more Tab leaves the stepper entirely (single stop, not two).
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(after.hasPrimaryFocus, isTrue);
  });

  testWidgets('stepper exposes increment/decrement semantics for a11y', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    double value = 10;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => AdaptiveSettingsStepperRow(
            title: 'Font size',
            value: value,
            step: 1,
            min: 0,
            max: 64,
            format: (v) => '${v.round()}',
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );

    // A screen reader must be able to raise/lower the value without the keyboard
    // arrow shortcuts (which are invisible to assistive tech).
    final Finder slider = find.byWidgetPredicate(
      (Widget w) => w is Semantics && (w.properties.slider ?? false),
    );
    expect(
      tester.getSemantics(slider),
      matchesSemantics(
        isSlider: true,
        value: '10',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );

    final SemanticsNode node = tester.getSemantics(slider);
    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(value, 11);

    handle.dispose();
  });

  testWidgets('Material settings rows register with Hibiki focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      _app(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              AdaptiveSettingsNavigationRow(
                title: 'Outer',
                onTap: () => taps += 1,
              ),
              AdaptiveSettingsNavigationRow(
                title: 'Inner',
                onTap: () => taps += 1,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.text('Outer'));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(controller.activeContext, isNotNull);

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });

  testWidgets(
      'HibikiFocusRing scrolls a programmatically-focused off-screen '
      'control into view (把视角转过去)', (tester) async {
    // Programmatic focus (node.requestFocus) does NOT go through the traversal
    // policy, so Flutter does not ensureVisible — only the focus ring does.
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final List<FocusNode> nodes =
        List<FocusNode>.generate(20, (_) => FocusNode());
    addTearDown(() {
      for (final FocusNode n in nodes) {
        n.dispose();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
        home: HibikiFocusRing(
          child: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 200, maxWidth: 400),
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < nodes.length; i++)
                        Focus(
                          focusNode: nodes[i],
                          child: const SizedBox(height: 48, width: 400),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final Rect viewport =
        _globalRect(find.byType(SingleChildScrollView), tester);

    // Focus the last control directly — far below the fold.
    nodes.last.requestFocus();
    await tester.pump(); // deliver focus change
    await tester.pumpAndSettle(); // let the ring's ensureVisible animation run

    final RenderBox box = nodes.last.context!.findRenderObject()! as RenderBox;
    final Rect focusRect = box.localToGlobal(Offset.zero) & box.size;

    expect(
      viewport.top <= focusRect.top + 1 &&
          focusRect.bottom <= viewport.bottom + 1,
      isTrue,
      reason: 'Off-screen focused control $focusRect should be scrolled into '
          'view $viewport by HibikiFocusRing',
    );
  });
}
