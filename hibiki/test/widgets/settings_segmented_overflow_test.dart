import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the reported layout bug: "A RenderFlex overflowed by 332 pixels
// on the right." on the settings page. An inline (controlBelow:false) segmented
// row hosts a wide [SegmentedButton] inside a horizontal scroll view. As a
// NON-flex Row child it was measured with UNBOUNDED width, so the scroll view
// sized to the strip's full intrinsic width and overflowed narrow detail panes
// every frame. It is now a flexible (bounded-width) trailing, so it scrolls.
void main() {
  Widget narrowSegmentedRow() {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        // A narrow detail pane just above the master-detail split width, where
        // the wide design-system strip used to overflow.
        width: 240,
        child: AdaptiveSettingsSegmentedRow<String>(
          title: 'Design system',
          subtitle: 'Choose the platform look',
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(
                value: 'material', label: Text('Material Design 3')),
            ButtonSegment<String>(value: 'cupertino', label: Text('iOS')),
            ButtonSegment<String>(value: 'auto', label: Text('Automatic')),
          ],
          selected: 'material',
          onChanged: (_) {},
        ),
      ),
    );
  }

  testWidgets(
    'inline segmented row shrink-and-scrolls in a narrow pane without overflow',
    (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(narrowSegmentedRow()));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow on a narrow pane');

      // The strip is genuinely scrollable now (bounded width → it scrolls
      // instead of clipping/overflowing).
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      final ScrollableState scrollable =
          tester.state(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, greaterThan(0.0),
          reason: 'the segmented strip exceeds the bounded width and scrolls');
    },
  );
}
