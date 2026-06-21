import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for two reported layout bugs on the settings page, both rooted in
// how a wide [SegmentedButton] is hosted inside an [AdaptiveSettingsSegmentedRow].
//
//  1. "A RenderFlex overflowed by 332 pixels on the right." — an INLINE
//     (controlBelow:false) segmented row hosting the strip in a horizontal
//     scroll view used to size it to the strip's full intrinsic width as a
//     NON-flex child and overflow narrow panes. It is now a flexible
//     (bounded-width) trailing, so the inline path scrolls instead.
//  2. BUG-008 (设计系统/深色模式 options clipped off the right edge) — the inline
//     path splits the row width ≈50/50 between the `Expanded` label and the
//     strip, so a strip wider than its share is clipped/scrolled and trailing
//     segments fall off-screen even when the PANE has plenty of room. The fix
//     makes [controlBelow] default to true: the strip gets its own full-width
//     row below the label, so the same strip that the inline path has to scroll
//     fits without scrolling and every segment is visible.
void main() {
  // Verbose labels so the strip is intrinsically wide (~700-800px): wide enough
  // that a ≈50/50 inline split must scroll it, yet narrower than the panes used
  // below — the exact regime where the inline split clipped segments.
  const List<ButtonSegment<String>> designSystemSegments =
      <ButtonSegment<String>>[
    ButtonSegment<String>(value: 'auto', label: Text('Automatic')),
    ButtonSegment<String>(value: 'material', label: Text('Material Design 3')),
    ButtonSegment<String>(value: 'cupertino', label: Text('iOS (Cupertino)')),
  ];

  Widget row({required double width, required bool? controlBelow}) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: width,
        child: controlBelow == null
            ? AdaptiveSettingsSegmentedRow<String>(
                // No controlBelow → exercises the shipped default the
                // appearance-page selectors (设计系统/深色模式) rely on.
                title: 'Design system',
                subtitle: 'Choose the platform look',
                segments: designSystemSegments,
                selected: 'material',
                onChanged: (_) {},
              )
            : AdaptiveSettingsSegmentedRow<String>(
                title: 'Design system',
                subtitle: 'Choose the platform look',
                controlBelow: controlBelow,
                segments: designSystemSegments,
                selected: 'material',
                onChanged: (_) {},
              ),
      ),
    );
  }

  double maxScrollOf(WidgetTester tester) =>
      (tester.state(find.byType(Scrollable).first) as ScrollableState)
          .position
          .maxScrollExtent;

  testWidgets(
    'inline segmented row shrink-and-scrolls in a narrow pane without overflow',
    (WidgetTester tester) async {
      await tester
          .pumpWidget(buildTestApp(row(width: 240, controlBelow: false)));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow on a narrow pane');

      // The strip is genuinely scrollable now (bounded width → it scrolls
      // instead of clipping/overflowing).
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(maxScrollOf(tester), greaterThan(0.0),
          reason: 'the segmented strip exceeds the bounded width and scrolls');
    },
  );

  testWidgets(
    'BUG-008: default segmented row lays the strip below the label so the '
    'whole strip is visible where the inline split would clip it',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const double pane = 1100;

      // Inline at this pane: the ≈50/50 split caps the strip at ~half (well
      // under its intrinsic width), so it must scroll — segments are clipped.
      await tester
          .pumpWidget(buildTestApp(row(width: pane, controlBelow: false)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final double inlineScroll = maxScrollOf(tester);
      expect(inlineScroll, greaterThan(0.0),
          reason: 'inline split squeezes the strip below its width → scrolls');

      // Default (controlBelow:true): same pane, but the strip owns a full-width
      // row below the label, so it fits and STRETCHES to fill the row (no
      // scroll). The strip fitting means it is no longer wrapped in a scroll
      // view at all (TODO-647 full-width-when-it-fits).
      await tester
          .pumpWidget(buildTestApp(row(width: pane, controlBelow: null)));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'no overflow when the strip owns its own row');

      final Rect label = tester.getRect(find.text('Design system'));
      final Rect strip = tester.getRect(find.byType(SegmentedButton<String>));

      // Structural proof: the strip is on its own row BELOW the label, not
      // squeezed beside it.
      expect(strip.top, greaterThanOrEqualTo(label.bottom - 0.5),
          reason: 'the segmented strip sits below the label (controlBelow)');

      // TODO-647: a fitting strip is laid out full-width, so it is NOT wrapped
      // in a horizontal scroll view (no Scrollable at all here).
      expect(find.byType(SingleChildScrollView), findsNothing,
          reason: 'a fitting strip stretches full-width, not scroll-hosted');

      // Symptom guard: the full strip — including the last "iOS" segment — fits
      // and nothing is clipped.
      final Rect lastSegment = tester.getRect(find.text('iOS (Cupertino)'));
      expect(lastSegment.right, lessThanOrEqualTo(strip.right + 0.5),
          reason: 'the last segment is within the strip bounds');
    },
  );

  testWidgets(
    'default segmented row scrolls long CJK labels at 2x scale without overflow',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildTestApp(
          Builder(
            builder: (BuildContext context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 300,
                    child: AdaptiveSettingsSegmentedRow<String>(
                      title: '閱讀方向和表示モード',
                      subtitle: '長い選択肢でも下段に逃がして横スクロールする',
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(
                          value: 'auto',
                          label: Text('自動判定'),
                        ),
                        ButtonSegment<String>(
                          value: 'vertical',
                          label: Text('縦書き優先'),
                        ),
                        ButtonSegment<String>(
                          value: 'spread',
                          label: Text('見開きページ表示'),
                        ),
                      ],
                      selected: 'auto',
                      onChanged: (_) {},
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'long segmented labels at 2x must scroll, not overflow',
      );
      expect(maxScrollOf(tester), greaterThan(0.0));
    },
  );
  testWidgets(
    'TODO-647: a fitting default strip stretches full-width with equal segments',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // A 3-segment strip with short labels in a roomy pane: it fits, so it must
      // stretch to fill the row (not shrink to its natural width on the left).
      const List<ButtonSegment<String>> shortSegments = <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'off', label: Text('Off')),
        ButtonSegment<String>(value: 'on', label: Text('On')),
        ButtonSegment<String>(value: 'auto', label: Text('Auto')),
      ];

      const double pane = 600;
      await tester.pumpWidget(
        buildTestApp(
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: pane,
              child: AdaptiveSettingsSegmentedRow<String>(
                title: 'Spread mode',
                subtitle: 'Choose page spread',
                segments: shortSegments,
                selected: 'auto',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Fits → no scroll host at all.
      expect(find.byType(SingleChildScrollView), findsNothing,
          reason: 'a fitting strip is laid out full-width, not scroll-hosted');

      // The strip stretches to (almost) the full row width — well beyond the
      // natural width of three short labels (~200px). Allow for row padding.
      final Rect strip = tester.getRect(find.byType(SegmentedButton<String>));
      expect(strip.width, greaterThan(pane - 40),
          reason: 'a fitting strip stretches to fill its full-width row');

      // Equal-width segments: the three labels are roughly evenly spaced across
      // the stretched strip, so the centre label sits near the strip centre.
      final double onCentre = tester.getCenter(find.text('On')).dx;
      expect((onCentre - strip.center.dx).abs(), lessThan(strip.width / 6),
          reason: 'segments share the stretched width equally');
    },
  );

  testWidgets(
    'TODO-647: a narrow pane with many/long segments falls back to scroll '
    '(BUG-008 segments stay reachable)',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Five verbose segments in a narrow pane: cannot fit full-width, so the
      // host must fall back to the horizontal scroll view so every segment
      // (including the last) stays reachable.
      const List<ButtonSegment<String>> manySegments = <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'a', label: Text('Automatic detect')),
        ButtonSegment<String>(value: 'b', label: Text('Vertical writing')),
        ButtonSegment<String>(value: 'c', label: Text('Horizontal writing')),
        ButtonSegment<String>(value: 'd', label: Text('Two-page spread')),
        ButtonSegment<String>(value: 'e', label: Text('Continuous scroll')),
      ];

      await tester.pumpWidget(
        buildTestApp(
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 300,
              child: AdaptiveSettingsSegmentedRow<String>(
                title: 'Reading layout',
                subtitle: 'Pick a layout',
                segments: manySegments,
                selected: 'a',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'a too-wide strip must scroll, not overflow');

      // Fell back to the scroll view, and it genuinely scrolls (the strip is
      // wider than the pane), so trailing segments are reachable.
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(maxScrollOf(tester), greaterThan(0.0),
          reason: 'narrow pane → strip scrolls, last segment reachable');
    },
  );
}
