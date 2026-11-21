import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/fushi_m3e_misc_themes.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_scrollbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:material_ui/material_ui.dart';

/// 11-20 反馈 #7：声音选择弹窗（`showFushiChoiceDialog` → `FushiSimpleDialog`）的
/// 滚动条贴在圆角外缘、一直画到弹窗底边。修好后拇指在面板里：右缘内缩
/// [kFushiDialogScrollbarCrossInset]，滚到底时离面板底边至少一个圆角半径。

/// 面板圆角（M3 对话框 extra-large）。
const double _cornerRadius = 28;

Widget _app() {
  final ColorScheme cs = ColorScheme.fromSeed(seedColor: Colors.indigo);
  return MaterialApp(
    scrollBehavior: const FushiScrollBehavior(),
    theme: ThemeData(
      colorScheme: cs,
      scrollbarTheme: fushiM3eScrollbarTheme(cs: cs, eink: false),
    ),
    home: Builder(
      builder: (BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showFushiChoiceDialog<int>(
              context: context,
              title: 'Voice',
              selected: 0,
              options: <FushiChoiceOption<int>>[
                for (int i = 0; i < 40; i++)
                  FushiChoiceOption<int>(
                    value: i,
                    label: 'Voice $i',
                    subtitle: 'Irodori',
                  ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final TargetPlatformVariant desktop = TargetPlatformVariant.only(
    TargetPlatform.windows,
  );

  testWidgets('choice dialog scrollbar thumb stays inside the rounded panel', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Finder panel = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Material),
    );
    final Rect panelRect = tester.getRect(panel.first);
    final Finder scrollbar = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate((Widget w) => w is RawScrollbar),
    );
    expect(scrollbar, findsOneWidget);
    final Rect barBox = tester.getRect(scrollbar);

    Rect? thumb;
    PaintPattern thumbPattern() =>
        paints..something((Symbol method, List<dynamic> args) {
          if (method != #drawRRect) return false;
          final RRect rrect = args.first as RRect;
          if ((rrect.width - kFushiScrollbarThickness).abs() > 0.01) {
            return false;
          }
          thumb = rrect.outerRect.shift(barBox.topLeft);
          return true;
        });

    // 静息（顶端）：右缘内缩、顶端让出圆角半径。
    expect(scrollbar, thumbPattern());
    expect(thumb, isNotNull);
    expect(
      thumb!.right,
      lessThanOrEqualTo(
        panelRect.right - kFushiDialogScrollbarCrossInset + 0.01,
      ),
    );
    expect(thumb!.top, greaterThanOrEqualTo(barBox.top + _cornerRadius - 0.01));

    // 滚到底：拇指底边离面板底边至少一个圆角半径，不压进弯角、不出界。
    await tester.drag(
      find.text('Voice 3'),
      const Offset(0, -6000),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    thumb = null;
    expect(scrollbar, thumbPattern());
    expect(thumb, isNotNull);
    expect(
      thumb!.bottom,
      lessThanOrEqualTo(panelRect.bottom - _cornerRadius + 0.01),
    );
    expect(
      thumb!.right,
      lessThanOrEqualTo(
        panelRect.right - kFushiDialogScrollbarCrossInset + 0.01,
      ),
    );
  }, variant: desktop);

  testWidgets('dialog shells apply the inset to their scrollbar theme', (
    WidgetTester tester,
  ) async {
    late ScrollbarThemeData inside;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiDialog(
            child: Builder(
              builder: (BuildContext context) {
                inside = ScrollbarTheme.of(context);
                return const SizedBox(width: 200, height: 200);
              },
            ),
          ),
        ),
      ),
    );
    expect(inside.crossAxisMargin, kFushiDialogScrollbarCrossInset);
    expect(inside.mainAxisMargin, _cornerRadius);
  });
}
