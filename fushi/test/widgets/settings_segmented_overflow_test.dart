import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

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
  const List<ButtonSegment<String>>
  designSystemSegments = <ButtonSegment<String>>[
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

  // 分段行三档摆放（[settingsSegmentedPlacement]）：少而短、估宽不超过行宽 55%
  // 时在行右侧；行内放不下但整行放得下每段文字时，分段换到标题下方并撑满整行
  // （2026-11-20 用户反馈：不再一律退成菜单）；连整行都放不下才退回「当前值写进
  // 说明行、点整行弹出菜单」的 [SettingsChoiceMenuRow]。BUG-008 / 溢出两条回归的
  // 契约因此是：任何宽度下都不溢出，且每个选项都可达（要么整条分段完整可见，
  // 要么全部出现在菜单里）。
  Future<void> expectOptionsReachable(
    WidgetTester tester, {
    required String selectedLabel,
    required List<String> otherLabels,
  }) async {
    final Finder strip = find.byWidgetPredicate(
      (Widget w) => w is SegmentedButton<String>,
    );
    if (find.byType(SettingsChoiceMenuRow).evaluate().isEmpty) {
      // 分段形态：整条可见，每段文字完整落在分段条里（没有被裁到画布外）。
      expect(strip, findsOneWidget, reason: 'either a whole strip or a menu');
      final Rect stripRect = tester.getRect(strip);
      final Rect screen = tester.getRect(find.byType(Scaffold));
      expect(stripRect.left, greaterThanOrEqualTo(screen.left - 0.5));
      expect(stripRect.right, lessThanOrEqualTo(screen.right + 0.5));
      for (final String label in <String>[selectedLabel, ...otherLabels]) {
        final Finder text = find.descendant(
          of: strip,
          matching: find.text(label),
        );
        expect(text, findsOneWidget, reason: 'segment visible: $label');
        final Rect r = tester.getRect(text);
        expect(r.left, greaterThanOrEqualTo(stripRect.left - 0.5));
        expect(r.right, lessThanOrEqualTo(stripRect.right + 0.5));
      }
      expect(tester.takeException(), isNull);
      return;
    }
    expect(
      strip,
      findsNothing,
      reason: 'no clipped / half-visible strip is left on the row',
    );
    expect(
      find.textContaining(selectedLabel),
      findsOneWidget,
      reason: 'the selected option is shown on the row itself',
    );
    await tester.tap(find.byType(SettingsChoiceMenuRow));
    await tester.pumpAndSettle();
    for (final String label in otherLabels) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'every option stays reachable from the menu: $label',
      );
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'inline segmented row in a narrow pane falls back to a menu without overflow',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(row(width: 240, controlBelow: false)),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'no RenderFlex overflow on a narrow pane',
      );
      await expectOptionsReachable(
        tester,
        selectedLabel: 'Material Design 3',
        otherLabels: <String>['Automatic', 'iOS (Cupertino)'],
      );
    },
  );

  for (final bool? controlBelow in <bool?>[false, null]) {
    testWidgets(
      'BUG-008: a long-label segmented row never clips trailing options in a '
      'wide pane (controlBelow: $controlBelow)',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          buildTestApp(row(width: 1100, controlBelow: controlBelow)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'no overflow');
        // 宽面板：分段要么在行内靠右，要么换到标题下方撑满整行——右缘都贴着
        // 行的右内边距，不会退成菜单、也不会靠左一小块留半行空白。
        final Rect strip = tester.getRect(
          find.byWidgetPredicate((Widget w) => w is SegmentedButton<String>),
        );
        final Rect rowRect = tester.getRect(
          find.byWidgetPredicate(
            (Widget w) => w is AdaptiveSettingsSegmentedRow<String>,
          ),
        );
        expect(strip.right, moreOrLessEquals(rowRect.right - 16, epsilon: 1));
        await expectOptionsReachable(
          tester,
          selectedLabel: 'Material Design 3',
          otherLabels: <String>['Automatic', 'iOS (Cupertino)'],
        );
      },
    );
  }

  testWidgets(
    'long CJK labels at 2x scale fall back to a menu without overflow',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildTestApp(
          Builder(
            builder: (BuildContext context) {
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
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
        reason: 'long segmented labels at 2x must not overflow',
      );
      await expectOptionsReachable(
        tester,
        selectedLabel: '自動判定',
        otherLabels: <String>['縦書き優先', '見開きページ表示'],
      );
    },
  );
  testWidgets(
    'TODO-647: a fitting short strip sits whole on the label row with equal '
    'segments',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const List<ButtonSegment<String>> shortSegments = <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'off', label: Text('Off')),
        ButtonSegment<String>(value: 'on', label: Text('On')),
        ButtonSegment<String>(value: 'auto', label: Text('Auto')),
      ];

      const double pane = 600;
      const Key paneKey = ValueKey<String>('pane');
      await tester.pumpWidget(
        buildTestApp(
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              key: paneKey,
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

      // Fits → shown as a real strip: not a menu, not scroll-hosted.
      expect(find.byType(SettingsChoiceMenuRow), findsNothing);
      expect(
        find.byType(SingleChildScrollView),
        findsNothing,
        reason: 'a fitting strip is laid out whole, not scroll-hosted',
      );

      final Rect strip = tester.getRect(
        find.byWidgetPredicate((Widget w) => w is SegmentedButton<String>),
      );
      final Rect label = tester.getRect(find.text('Spread mode'));
      final Rect row = tester.getRect(find.byKey(paneKey));
      // Compact trailing control on the label row (Android 16 settings),
      // right-aligned to the row content edge, within its 55% share.
      expect(
        strip.top,
        lessThan(label.bottom),
        reason: 'the strip sits on the label row, not below it',
      );
      expect(
        strip.left,
        greaterThan(label.right),
        reason: 'the strip trails the label',
      );
      expect(
        row.right - strip.right,
        lessThan(40),
        reason: 'the strip is right-aligned to the row content edge',
      );
      expect(strip.width, lessThanOrEqualTo(pane * 0.55));
      // Every segment is fully inside the strip (nothing clipped).
      for (final String text in <String>['Off', 'On', 'Auto']) {
        final Rect r = tester.getRect(find.text(text));
        expect(r.left, greaterThanOrEqualTo(strip.left - 0.5));
        expect(r.right, lessThanOrEqualTo(strip.right + 0.5));
      }

      // Equal-width segments: the centre label sits near the strip centre.
      final double onCentre = tester.getCenter(find.text('On')).dx;
      expect(
        (onCentre - strip.center.dx).abs(),
        lessThan(strip.width / 6),
        reason: 'segments share the strip width equally',
      );
    },
  );

  testWidgets(
    'TODO-647: a narrow pane with many/long segments falls back to a menu '
    '(BUG-008 segments stay reachable)',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

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
      expect(
        tester.takeException(),
        isNull,
        reason: 'a too-wide strip must not overflow',
      );

      await expectOptionsReachable(
        tester,
        selectedLabel: 'Automatic detect',
        otherLabels: <String>[
          'Vertical writing',
          'Horizontal writing',
          'Two-page spread',
          'Continuous scroll',
        ],
      );
    },
  );
}
