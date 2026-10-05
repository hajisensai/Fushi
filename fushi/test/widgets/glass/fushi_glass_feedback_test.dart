import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 反馈包装契约：MD3 下是 M3 Expressive 波浪进度 / 原 tooltip；Apple 下确定态是
// Apple 细轨 / 细圆环（强调色）、不定态圆形是 iOS 菊花
// CupertinoActivityIndicator，tooltip 气泡是 GlassContainer。

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool glass,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(child: SizedBox(width: 300, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('MD3 builds the original indicators and tooltip', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: <Widget>[
          FushiLinearProgressIndicator(value: 0.4, minHeight: 6),
          FushiCircularProgressIndicator(value: 0.5, strokeWidth: 2),
          FushiCircularProgressIndicator.adaptive(value: 0.5),
          FushiTooltip(message: 'tip', child: Text('anchor')),
        ],
      ),
      glass: false,
    );
    // MD3 = Material 3 Expressive 波浪进度（自绘）；`.adaptive` 在测试平台
    // （Android）上同样走波浪环。
    expect(find.byType(FushiWavyLinearProgress), findsOneWidget);
    expect(find.byType(FushiWavyCircularProgress), findsNWidgets(2));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Tooltip), findsOneWidget);
    expect(find.byType(FushiAppleLinearProgress), findsNothing);
    final FushiWavyLinearProgress linear = tester.widget(
      find.byType(FushiWavyLinearProgress),
    );
    expect(linear.strokeWidth, 6);
    // 波浪相位动画在跑，不能 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('glass builds Apple progress with scheme colors', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: <Widget>[
          FushiLinearProgressIndicator(value: 0.4, minHeight: 6),
          FushiCircularProgressIndicator(strokeWidth: 2),
          FushiCircularProgressIndicator.adaptive(value: 0.5),
          FushiCircularProgressIndicator(value: 0.2, color: Colors.orange),
        ],
      ),
      glass: true,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 不定态圆形进度是 iOS 菊花；线性是 Apple 细轨；确定态圆形是细圆环。
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    final FushiAppleLinearProgress linear = tester.widget(
      find.byType(FushiAppleLinearProgress),
    );
    final List<FushiAppleProgressRing> rings = tester
        .widgetList<FushiAppleProgressRing>(find.byType(FushiAppleProgressRing))
        .toList();
    expect(rings, hasLength(2));
    final BuildContext ctx = tester.element(find.byType(Column));
    final Color primary = Theme.of(ctx).colorScheme.primary;
    expect(linear.color, primary);
    expect(linear.height, 6);
    expect(linear.value, 0.4);
    expect(rings[0].color, primary);
    expect(rings[1].color, Colors.orange);
    // 线性条撑满父级宽度（与 Material 一致）。
    expect(tester.getSize(find.byType(FushiAppleLinearProgress)).width, 300);
    // 不定态动画在跑，不能 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('glass tooltip keeps Tooltip behaviour with a glass bubble', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const FushiTooltip(
        message: 'Glass tip',
        triggerMode: TooltipTriggerMode.tap,
        child: Text('anchor'),
      ),
      glass: true,
    );
    expect(find.byType(Tooltip), findsOneWidget);
    // 无障碍提示仍是消息文本。
    expect(
      tester.getSemantics(find.text('anchor')),
      matchesSemantics(tooltip: 'Glass tip', label: 'anchor'),
    );
    await tester.tap(find.text('anchor'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Glass tip'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Glass tip'),
        matching: find.byType(GlassContainer),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
