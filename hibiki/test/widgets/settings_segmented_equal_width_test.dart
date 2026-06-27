import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// TODO-882: the segmented boxes in the settings "布局与显示" section must all be
// EQUAL WIDTH. The section renders its rows in a `CrossAxisAlignment.stretch`
// Column, so every row gets the same available width. Previously a SHORT strip
// (fits) stretched to fill that width while a LONG strip (does not fit) fell
// back to a bare horizontal scroll view that sized itself to the strip's narrow
// INTRINSIC width — so two boxes in the same section rendered at different
// widths. The fix makes a controlBelow strip ALWAYS occupy the full row width
// (`SizedBox(width: double.infinity)`), scrolling its content inside when it
// does not fit, so both boxes are equally full-width.
void main() {
  // A short 2-segment strip that fits the pane full-width without scrolling.
  const List<ButtonSegment<String>> shortSegments = <ButtonSegment<String>>[
    ButtonSegment<String>(value: 'h', label: Text('横')),
    ButtonSegment<String>(value: 'v', label: Text('縦')),
  ];

  // A long 4-segment strip with CJK labels that cannot fit the same pane
  // full-width and must fall back to horizontal scrolling (the furigana_mode /
  // narrow-pane spread_mode case that previously rendered narrower).
  const List<ButtonSegment<String>> longSegments = <ButtonSegment<String>>[
    ButtonSegment<String>(value: 'a', label: Text('自動判定で表示')),
    ButtonSegment<String>(value: 'b', label: Text('常に振り仮名を表示')),
    ButtonSegment<String>(value: 'c', label: Text('振り仮名を一切表示しない')),
    ButtonSegment<String>(value: 'd', label: Text('読了済みの語だけ隠す')),
  ];

  // Mirror the real section host: a stretch Column so both rows get the same
  // available width, exactly like material_settings_renderer's section body.
  Widget section({required double width}) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            AdaptiveSettingsSegmentedRow<String>(
              key: ValueKey<String>('short'),
              title: '縦書き / 横書き',
              segments: shortSegments,
              selected: 'h',
              onChanged: _noop,
            ),
            AdaptiveSettingsSegmentedRow<String>(
              key: ValueKey<String>('long'),
              title: 'ふりがな表示',
              segments: longSegments,
              selected: 'a',
              onChanged: _noop,
            ),
          ],
        ),
      ),
    );
  }

  // The full-width host box for each row is the `SizedBox(width:
  // double.infinity)` that `_SegmentedStripHost` emits below the label. Both the
  // fitting (child == strip) and the scrolling (child == SingleChildScrollView)
  // branches wrap that infinite-width box, so finding the box under each keyed
  // row and comparing its painted width proves equal width.
  double hostWidthUnder(WidgetTester tester, String rowKey) {
    final Finder host = find.descendant(
      of: find.byKey(ValueKey<String>(rowKey)),
      matching: find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.width == double.infinity,
      ),
    );
    expect(host, findsOneWidget,
        reason: 'each controlBelow strip is hosted in a full-width box');
    return tester.getSize(host).width;
  }

  testWidgets(
    'TODO-882: short and long segmented boxes in one section are equal width',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(520, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // A pane that fits the short strip full-width but is too narrow for the
      // long CJK strip — the exact regime where widths used to diverge.
      const double pane = 460;
      await tester.pumpWidget(buildTestApp(section(width: pane)));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final double shortWidth = hostWidthUnder(tester, 'short');
      final double longWidth = hostWidthUnder(tester, 'long');

      // Both boxes span the same full available width: EQUAL.
      expect((shortWidth - longWidth).abs(), lessThan(0.5),
          reason: 'both segmented boxes occupy the same full row width');

      // And both really do fill the row (≈ pane minus row horizontal padding),
      // not the strip's narrow intrinsic width.
      expect(shortWidth, greaterThan(pane - 40),
          reason: 'the short box fills the row');
      expect(longWidth, greaterThan(pane - 40),
          reason: 'the long box fills the row, not its intrinsic narrow width');

      // BUG-008 guard: the long strip is genuinely scrollable inside its
      // full-width box, so the trailing segment stays reachable.
      final Finder longScroll = find.descendant(
        of: find.byKey(const ValueKey<String>('long')),
        matching: find.byType(SingleChildScrollView),
      );
      expect(longScroll, findsOneWidget,
          reason: 'the long strip scrolls inside its full-width box');
      final ScrollableState scrollState = tester.state(
        find.descendant(
          of: find.byKey(const ValueKey<String>('long')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollState.position.maxScrollExtent, greaterThan(0.0),
          reason: 'the long strip overflows its box → scrolls to last segment');

      // The short strip fits, so it is NOT scroll-hosted (full-width equal
      // segments instead).
      final Finder shortScroll = find.descendant(
        of: find.byKey(const ValueKey<String>('short')),
        matching: find.byType(SingleChildScrollView),
      );
      expect(shortScroll, findsNothing,
          reason: 'the fitting short strip stretches, no scroll host');
    },
  );
}

void _noop(String _) {}
