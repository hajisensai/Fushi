import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4397: the Apple segmented control (single choice, the
/// [adaptiveSegmentedButton] form and the multi-choice fallback) must answer
/// intrinsic size queries: a form dialog sizes its content with
/// [IntrinsicWidth], and a bare LayoutBuilder threw there.
void main() {
  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<void> pump(WidgetTester tester, bool apple, Widget child) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(apple: apple),
        home: FushiGlassScope(
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  Widget single(BuildContext context) => adaptiveSegmentedButton<int>(
    context: context,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('Chapter')),
      ButtonSegment<int>(value: 1, label: Text('Volume')),
    ],
    selected: const <int>{0},
    onSelectionChanged: (_) {},
  );

  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'Material';
    testWidgets('inside IntrinsicWidth the single choice lays out at its '
        'content width ($design)', (WidgetTester tester) async {
      await pump(
        tester,
        apple,
        IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Builder(builder: single),
              const Text('Starting number'),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final Size size = tester.getSize(find.byType(IntrinsicWidth));
      expect(size.width, greaterThan(100));
      expect(size.width, lessThan(600), reason: 'content width, not 900');
    });

    testWidgets('in a bounded column the single choice fills the width '
        '($design)', (WidgetTester tester) async {
      await pump(
        tester,
        apple,
        SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[Builder(builder: single)],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      if (apple) {
        expect(
          tester.getSize(find.byType(FushiAppleSegmentedControl)).width,
          moreOrLessEquals(500, epsilon: 1),
        );
      }
    });
  }

  testWidgets(
    'inside IntrinsicWidth the Apple multi-choice fallback lays out',
    (WidgetTester tester) async {
      await pump(
        tester,
        true,
        IntrinsicWidth(
          child: FushiSegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('Anime')),
              ButtonSegment<int>(value: 1, label: Text('Manga')),
            ],
            selected: const <int>{},
            emptySelectionAllowed: true,
            multiSelectionEnabled: true,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: (_) {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
