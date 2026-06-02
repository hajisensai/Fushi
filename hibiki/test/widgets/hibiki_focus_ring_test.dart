import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

void main() {
  test('HibikiFocusRing uses design token radius', () {
    final String source =
        File('lib/src/utils/components/hibiki_focus_ring.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('tokens.radii.chipRadius'));
    expect(source, contains('HibikiFocusScroll.ensureVisibleIfHidden'));
    expect(source, isNot(contains('BorderRadius.circular(8)')));
    expect(source, isNot(contains('Scrollable.ensureVisible')));
  });

  testWidgets('HibikiFocusRing builds and overlays its child',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRing(
        child: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('x')),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('x'), findsOneWidget);
    expect(find.byType(HibikiFocusRing), findsOneWidget);
  });

  testWidgets(
      'does not throw when a focused sibling is removed while the ring '
      'rebuilds in the same frame (desktop startup regression)',
      (WidgetTester tester) async {
    // Desktop defaults to the traditional (keyboard) highlight mode from
    // launch, so the focus-ring geometry path runs immediately — unlike mobile
    // (touch mode), where it is skipped. Reading the focused element's geometry
    // during build crashed with "Cannot get renderObject of inactive element".
    //
    // Reproduction: the focused widget is a sibling placed BEFORE the ring in
    // the parent's children, and the ring's child changes with the toggle so
    // the ring rebuilds in the same pass. When the parent rebuilds, the focused
    // sibling is reconciled (deactivated) first while it is still the primary
    // focus (the focus change is only applied on a later microtask); the ring
    // then builds in the same pass — the moment a build-time findRenderObject()
    // would hit the inactive element.
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);

    late StateSetter setOuter;
    bool show = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return Column(
              children: <Widget>[
                if (show)
                  Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(width: 30, height: 30),
                  ),
                HibikiFocusRing(
                  // Child identity changes with `show`, forcing the ring to
                  // rebuild in the same pass that removes the focused sibling.
                  child: SizedBox(
                      key: ValueKey<bool>(show), width: 10, height: 10),
                ),
              ],
            );
          },
        ),
      ),
    ));
    await tester.pump();
    expect(node.hasFocus, isTrue);

    setOuter(() => show = false);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'renders a focus ring for a stable focused widget in '
      'traditional mode', (WidgetTester tester) async {
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRing(
        child: Scaffold(
          body: Center(
            child: Focus(
              focusNode: node,
              autofocus: true,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // post-frame rect computation
    await tester.pump(); // setState -> ring drawn

    expect(tester.takeException(), isNull);
    // The ring is an IgnorePointer-wrapped DecoratedBox positioned over focus.
    expect(find.byType(IgnorePointer), findsWidgets);
  });

  testWidgets(
      'ring follows the focused control when the in-app UI scale changes',
      (WidgetTester tester) async {
    // Regression: dragging the "界面大小" (app UI scale) slider reflows the whole
    // subtree via HibikiAppUiScale's Transform — moving the focused control —
    // without any window-metrics, focus, scroll, or highlight change. None of
    // the ring's recompute triggers fired, so the ring stayed pinned to the
    // control's old position ("焦点不跟着动").
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    const Key focusKey = ValueKey<String>('scaled-focus-target');

    late StateSetter setOuter;
    double scale = 1.0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          setOuter = setState;
          return HibikiAppUiScale(
            scale: scale,
            child: HibikiFocusRing(
              child: Scaffold(
                body: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // Height scales with textScaler, so the focus target below
                    // it shifts down when the UI scale grows.
                    const Text('header', style: TextStyle(fontSize: 48)),
                    Focus(
                      focusNode: node,
                      autofocus: true,
                      child: const SizedBox(
                        key: focusKey,
                        width: 40,
                        height: 40,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ));
    await tester.pump(); // post-frame rect computation
    await tester.pump(); // setState -> ring drawn

    // The ring is the only bordered DecoratedBox in the subtree.
    final Finder ringIndicator = find.descendant(
      of: find.byType(HibikiFocusRing),
      matching: find.byWidgetPredicate((Widget w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border != null),
    );
    expect(ringIndicator, findsOneWidget);

    // Ring sits at the focused control's rect inflated by 2px.
    final Offset focusTopLeft = tester.getTopLeft(find.byKey(focusKey));
    Offset ringTopLeft = tester.getTopLeft(ringIndicator);
    expect((ringTopLeft - (focusTopLeft - const Offset(2, 2))).distance,
        lessThan(0.5),
        reason: 'ring should align to focus at scale 1.0');

    // Grow the UI scale: the header text gets taller, pushing the focus target
    // down. No window resize / focus change / scroll happens.
    setOuter(() => scale = 2.0);
    await tester.pump(); // rebuild with new scale (reflow)
    await tester.pump(); // didChangeDependencies-scheduled recompute
    await tester.pump(); // setState -> ring repositioned

    final Offset movedFocusTopLeft = tester.getTopLeft(find.byKey(focusKey));
    expect(movedFocusTopLeft.dy, greaterThan(focusTopLeft.dy),
        reason: 'sanity: focus target moved down after scale increase');

    ringTopLeft = tester.getTopLeft(ringIndicator);
    expect((ringTopLeft - (movedFocusTopLeft - const Offset(2, 2))).distance,
        lessThan(0.5),
        reason: 'ring must follow the focus target after a UI scale change');
  });

  testWidgets(
      'ring on-screen size tracks the scaled control (not just position)',
      (WidgetTester tester) async {
    // Regression: the ring's rect was built as `localToGlobal(Offset.zero) &
    // ro.size` — a scaled top-left but the control's UN-scaled local size. build()
    // then divides by the scale, so the ring SHRANK as the UI zoomed in (44px ring
    // around an 80px control at 2.0×) instead of growing with it ("大小没缩放").
    // Map both corners through localToGlobal so the rect carries the on-screen
    // size. getRect returns GLOBAL (view-space) coords — the true visual rect the
    // Transform produces — so this asserts what the user actually sees.
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    const Key focusKey = ValueKey<String>('scaled-size-target');

    late StateSetter setOuter;
    double scale = 1.0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          setOuter = setState;
          return HibikiAppUiScale(
            scale: scale,
            child: HibikiFocusRing(
              child: Scaffold(
                body: Center(
                  child: Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(key: focusKey, width: 40, height: 40),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ));
    await tester.pump();
    await tester.pump();

    final Finder ring = find.descendant(
      of: find.byType(HibikiFocusRing),
      matching: find.byWidgetPredicate((Widget w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border != null),
    );

    // The ring must stay the control's on-screen rect inflated by exactly 2px at
    // every scale — a constant visual gap, with the control portion scaling.
    void expectRingHugsControl(double s) {
      final Rect control = tester.getRect(find.byKey(focusKey));
      final Rect r = tester.getRect(ring);
      expect(r.left, closeTo(control.left - 2, 0.6), reason: 'left @ $s');
      expect(r.top, closeTo(control.top - 2, 0.6), reason: 'top @ $s');
      expect(r.width, closeTo(control.width + 4, 0.6),
          reason: 'width must track scaled control @ $s');
      expect(r.height, closeTo(control.height + 4, 0.6),
          reason: 'height must track scaled control @ $s');
    }

    expectRingHugsControl(1.0);

    setOuter(() => scale = 2.0);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    // Control is 80px on screen at 2.0×; ring must be 84px, not the old 44px.
    expect(tester.getRect(find.byKey(focusKey)).width, closeTo(80, 0.6),
        reason: 'sanity: control doubles on screen at 2.0×');
    expectRingHugsControl(2.0);

    setOuter(() => scale = 0.5);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expectRingHugsControl(0.5);
  });

  testWidgets(
      'a theme change does not yank a manually-scrolled-away focus back',
      (WidgetTester tester) async {
    // didChangeDependencies fires for ANY inherited dependency the ring reads in
    // build() — including Theme.of. A theme change must NOT trigger the
    // reveal/scroll path: it does not move geometry, and pulling a deliberately
    // scrolled-away focus back to center would break the "manual scroll is not
    // pulled back" contract. Only a real in-app UI-scale change may scroll.
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    late StateSetter setOuter;
    bool dark = false;
    await tester.pumpWidget(StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        setOuter = setState;
        return MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: HibikiAppUiScale(
            scale: 1.0,
            child: HibikiFocusRing(
              child: Scaffold(
                // SingleChildScrollView keeps every child mounted regardless of
                // scroll, so the focused node stays alive (and primary) when we
                // scroll it off-screen — isolating the theme path from any
                // focus-change-driven reveal.
                body: SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: <Widget>[
                      const SizedBox(height: 400),
                      Focus(
                        focusNode: node,
                        autofocus: true,
                        child: const SizedBox(width: 40, height: 40),
                      ),
                      const SizedBox(height: 2000),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ));
    await tester.pump(); // autofocus + initial reveal (focus already visible)
    await tester.pump();

    // Manually scroll the focused control fully above the viewport. A manual
    // scroll must never be pulled back.
    controller.jumpTo(800);
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue,
        reason: 'focus stays alive while scrolled away (kept mounted)');
    expect(controller.offset, 800.0);

    // Toggle the theme: changes Theme.of below the ring → didChangeDependencies,
    // but textScaler is unchanged. The ring must NOT scroll.
    setOuter(() => dark = true);
    await tester.pump(); // rebuild with new theme
    await tester.pump(); // any scheduled post-frame callbacks
    await tester.pump();

    expect(controller.offset, 800.0,
        reason:
            'theme change must not scroll the manually-positioned viewport');
  });
}
