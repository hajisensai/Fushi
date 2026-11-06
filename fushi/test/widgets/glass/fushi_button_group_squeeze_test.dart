import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// 反馈 orCq_DE1i7：MD3 标准按钮组里按下右边的按钮，左边的「分享主题」被挤到比
// 单行还窄、文字折成两行。契约：邻居只让出超出自身单行固有宽的富余——按自然宽
// 排布的组按下时邻居尺寸纹丝不动；撑满整行的组照常挤压，但邻居永不窄于单行宽。
void main() {
  Future<void> pumpGroup(
    WidgetTester tester, {
    required bool expanded,
    double width = 600,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: false,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FushiButtonGroup(
                    expanded: expanded,
                    children: <Widget>[
                      FushiFilledButton.tonal(
                        key: const ValueKey<String>('left'),
                        onPressed: () {},
                        child: const Text('分享主题'),
                      ),
                      FushiFilledButton.tonal(
                        key: const ValueKey<String>('right'),
                        onPressed: () {},
                        child: const Text('更多'),
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
  }

  Future<TestGesture> pressRight(WidgetTester tester) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('right'))),
    );
    // 弹簧走完（fast spatial 远短于 1 秒）。
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return gesture;
  }

  Size leftSize(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey<String>('left')));

  testWidgets('natural-width group: pressing a button never shrinks its '
      'neighbour', (WidgetTester tester) async {
    await pumpGroup(tester, expanded: false);
    final Size before = leftSize(tester);
    final double rightBefore = tester
        .getSize(find.byKey(const ValueKey<String>('right')))
        .width;

    final TestGesture gesture = await pressRight(tester);
    expect(leftSize(tester), before);
    // 没有富余可借：被按下的按钮也不越界变宽（组外框不抖）。
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('right'))).width,
      rightBefore,
    );
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(leftSize(tester), before);
  });

  testWidgets('expanded group: neighbour gives spare width but never drops '
      'below its single-line width', (WidgetTester tester) async {
    // 先量出左按钮单行自然宽与高。
    await pumpGroup(tester, expanded: false);
    final Size natural = leftSize(tester);

    await pumpGroup(tester, expanded: true, width: 600);
    final double rightBefore = tester
        .getSize(find.byKey(const ValueKey<String>('right')))
        .width;
    final TestGesture gesture = await pressRight(tester);
    final Size squeezed = leftSize(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('right'))).width,
      greaterThan(rightBefore),
      reason: 'expanded group still has the M3E press growth',
    );
    expect(squeezed.width, greaterThanOrEqualTo(natural.width - 0.01));
    expect(squeezed.height, natural.height, reason: 'label must not wrap');
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('expanded group packed to its natural width: no squeeze', (
    WidgetTester tester,
  ) async {
    await pumpGroup(tester, expanded: false);
    final Size natural = leftSize(tester);
    final double rightNatural = tester
        .getSize(find.byKey(const ValueKey<String>('right')))
        .width;
    // 恰好放下两枚按钮（8 = 默认间距）：撑满后没有任何富余。
    await pumpGroup(
      tester,
      expanded: true,
      width: natural.width + rightNatural + 8,
    );
    final TestGesture gesture = await pressRight(tester);
    expect(leftSize(tester).width, closeTo(natural.width, 0.01));
    expect(leftSize(tester).height, natural.height);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
