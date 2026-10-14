import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// 确定态波浪进度只在值变化时流动：静止的进度展示（首页继续观看卡片的观看进度
// 等）不得常驻 ticker、每个 vsync 整帧重绘——那会让主线程从启动起一直被占着
// （profile 实测：一张继续观看卡片 ≈ 主线程 17% 常驻占用）。不定态照常一直转。

Future<void> _pump(WidgetTester tester, Widget child) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: false,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(child: SizedBox(width: 200, height: 60, child: child)),
        ),
      ),
    ),
  );
}

/// 让一次性的进入 / 补间动画走完后，判断是否还有东西在逐帧驱动。
Future<bool> _stillTicking(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  return tester.binding.hasScheduledFrame;
}

Widget _linear(double? value) => FushiWavyLinearProgress(
  value: value,
  color: Colors.teal,
  trackColor: Colors.black12,
);

Widget _circular(double? value) => FushiWavyCircularProgress(
  value: value,
  color: Colors.teal,
  trackColor: Colors.black12,
);

void main() {
  for (final (String name, Widget Function(double?) build) variant
      in <(String, Widget Function(double?))>[
        ('linear', _linear),
        ('circular', _circular),
      ]) {
    final String kind = variant.$1;
    final Widget Function(double?) build = variant.$2;

    testWidgets('$kind: static determinate value does not keep a ticker', (
      WidgetTester tester,
    ) async {
      await _pump(tester, build(0.42));
      expect(await _stillTicking(tester), isFalse);
    });

    testWidgets('$kind: value change flows, then settles when it stops', (
      WidgetTester tester,
    ) async {
      await _pump(tester, build(0.42));
      expect(await _stillTicking(tester), isFalse);

      await _pump(tester, build(0.5));
      expect(await _stillTicking(tester), isTrue, reason: '值在推进时应流动');

      await tester.pump(kWavyProgressFlowSettle);
      expect(await _stillTicking(tester), isFalse, reason: '值停住后应停止流动');

      await _pump(tester, build(0.6));
      expect(await _stillTicking(tester), isTrue, reason: '再次推进时恢复流动');
      await tester.pump(kWavyProgressFlowSettle);
    });

    testWidgets('$kind: indeterminate keeps animating', (
      WidgetTester tester,
    ) async {
      await _pump(tester, build(null));
      expect(await _stillTicking(tester), isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(await _stillTicking(tester), isTrue);
    });
  }
}
