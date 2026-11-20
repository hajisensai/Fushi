import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

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

  // 分段行三档摆放（settingsSegmentedPlacement，2026-11-20 重做）：放得下的少而
  // 短选项是行右侧紧凑分段；行内放不下但整行放得下时，分段换到标题下方撑满整行；
  // 连整行都放不下才退回菜单行。TODO-882 的诉求（同一 section 里控件不能一宽
  // 一窄、参差不齐）因此落成：两行占满同一 section 宽度、分段控件右缘都对齐到
  // 行内容边，长选项不留一个按固有宽度缩窄的盒子，全部选项仍可达。
  testWidgets(
    'TODO-882: short and long segmented rows in one section line up on the '
    'same full-width rows',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(520, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const double pane = 460;
      await tester.pumpWidget(buildTestApp(section(width: pane)));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final Rect shortRow = tester.getRect(
        find.byKey(const ValueKey<String>('short')),
      );
      final Rect longRow = tester.getRect(
        find.byKey(const ValueKey<String>('long')),
      );

      // Both rows span the same full section width: EQUAL.
      expect(
        (shortRow.width - longRow.width).abs(),
        lessThan(0.5),
        reason: 'both rows occupy the same full row width',
      );
      expect(
        shortRow.width,
        greaterThan(pane - 1),
        reason: 'rows fill the section, not an intrinsic narrow width',
      );

      // The short strip is a compact control right-aligned to the row content
      // edge (no stray narrow box floating on the left).
      final Rect shortStrip = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('short')),
          matching: find.byWidgetPredicate(
            (Widget w) => w is SegmentedButton<String>,
          ),
        ),
      );
      expect(
        shortRow.right - shortStrip.right,
        lessThan(40),
        reason: 'the short strip is right-aligned to the row edge',
      );

      // The long strip does not fit inline → it moves below the label and
      // spans the whole row (or, when even a full row cannot hold it, the row
      // becomes a choice-menu row); never a narrower intrinsic-width box.
      const List<String> longLabels = <String>[
        '自動判定で表示',
        '常に振り仮名を表示',
        '振り仮名を一切表示しない',
        '読了済みの語だけ隠す',
      ];
      final Finder longStrip = find.descendant(
        of: find.byKey(const ValueKey<String>('long')),
        matching: find.byWidgetPredicate(
          (Widget w) => w is SegmentedButton<String>,
        ),
      );
      if (longStrip.evaluate().isNotEmpty) {
        final Rect strip = tester.getRect(longStrip);
        expect(
          strip.width,
          moreOrLessEquals(longRow.width - 32, epsilon: 1),
          reason: 'a below strip spans the full row content width',
        );
        expect(
          longRow.right - strip.right,
          moreOrLessEquals(shortRow.right - shortStrip.right, epsilon: 1),
          reason: 'both strips end on the same row content edge',
        );
        for (final String label in longLabels) {
          expect(
            find.descendant(of: longStrip, matching: find.text(label)),
            findsOneWidget,
            reason: 'every long option stays visible: $label',
          );
        }
      } else {
        final Finder longMenu = find.descendant(
          of: find.byKey(const ValueKey<String>('long')),
          matching: find.byType(SettingsChoiceMenuRow),
        );
        expect(longMenu, findsOneWidget);
        await tester.tap(longMenu);
        await tester.pumpAndSettle();
        for (final String label in longLabels.skip(1)) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: 'every long option stays reachable: $label',
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
}

void _noop(String _) {}
