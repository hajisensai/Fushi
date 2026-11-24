// 首页小组件外框 / 周柱 / 大数字在 Cupertino（isGlassDesign）下不混 M3E 组件：
// 外框是 [HomeAppleWidgetCard]（无 InkWell 墨水、无 M3E 圆角 Material），周柱挂
// Swift Charts 式星期首字母，大数字是 Apple label 色；MD3 下原样（InkWell 分区卡、
// 不画星期行）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  const List<String> axis = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  int taps = 0;

  Widget app({required bool apple}) => MaterialApp(
    theme: theme(apple: apple),
    builder: (BuildContext context, Widget? child) =>
        FushiGlassScope(child: child!),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          height: 200,
          child: HomeWidgetFrame(
            title: 'Past week',
            icon: FushiIcons.barChart,
            hueKey: 'week',
            poster: false,
            dense: false,
            onTap: () => taps++,
            tapKey: const ValueKey<String>('frame-tap'),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                HomeWidgetFigure(value: '226', unit: 'chars'),
                SizedBox(height: 8),
                HomeWeekBars(
                  values: <int>[0, 3, 0, 5, 1, 0, 9],
                  labels: <String>['a', 'b', 'c', 'd', 'e', 'f', 'g'],
                  semanticLabel: 'week',
                  height: 60,
                  axisLabels: axis,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('Cupertino：外框 / 周柱 / 大数字不混 M3E', (WidgetTester tester) async {
    taps = 0;
    await tester.pumpWidget(app(apple: true));
    await tester.pumpAndSettle();

    expect(find.byType(HomeAppleWidgetCard), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    // 外框底色是 secondarySystemGroupedBackground。
    final BuildContext ctx = tester.element(find.byType(HomeAppleWidgetCard));
    final FushiAppleColors a = appleColorsOf(ctx);
    final ShapeDecoration deco =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byType(HomeAppleWidgetCard),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration;
    expect(deco.color, a.secondaryGroupedBackground);
    expect(deco.shape, isA<RoundedSuperellipseBorder>());
    // 小标题是学习类的类别色（系统橙），不是 M3E sectionLabel。
    final Text header = tester.widget<Text>(find.text('Past week'));
    expect(header.style?.color, a.warning);
    // Swift Charts 式星期首字母。
    expect(find.text('M'), findsOneWidget);
    expect(find.text('T'), findsNWidgets(2));
    // 大数字取 Apple label。
    final RichText figure = tester.widget<RichText>(
      find.descendant(
        of: find.byType(HomeWidgetFigure),
        matching: find.byType(RichText),
      ),
    );
    final TextSpan root = figure.text as TextSpan;
    expect((root.children!.first as TextSpan).style?.color, a.label);

    await tester.tap(find.byKey(const ValueKey<String>('frame-tap')));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('MD3：仍是 InkWell 分区卡、不画星期行', (WidgetTester tester) async {
    taps = 0;
    await tester.pumpWidget(app(apple: false));
    await tester.pumpAndSettle();

    expect(find.byType(HomeAppleWidgetCard), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is InkWell && w.key == const ValueKey<String>('frame-tap'),
      ),
      findsOneWidget,
    );
    expect(find.text('M'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('frame-tap')));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
