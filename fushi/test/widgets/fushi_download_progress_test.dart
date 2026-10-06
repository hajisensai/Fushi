import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_download_progress.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// 下载进度统一组件契约：MD3 确定态 = Expressive 波浪环 + 中心百分比，不定态 =
// Expressive 变形加载指示 + 已下载字节；Apple 确定态 = iOS 细圆环（不用波浪）；
// 读屏读出百分比；下满 100% 淡出。

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool glass = false,
  bool disableAnimations = false,
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
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: SizedBox(width: 120, height: 180, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('MD3 确定态：波浪环 + 中心百分比，读屏读百分比', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(value: 0.42, semanticsLabel: '下载中'),
    );
    expect(find.byType(FushiWavyCircularProgress), findsOneWidget);
    expect(find.byType(FushiAppleProgressRing), findsNothing);
    expect(find.text('42%'), findsOneWidget);
    final SemanticsNode node = tester.getSemantics(
      find.bySemanticsLabel('下载中'),
    );
    expect(node.value, '42%');
    semantics.dispose();
  });

  testWidgets('MD3 不定态：Expressive 加载指示 + 已下载字节', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(value: null, receivedBytes: 12900000),
    );
    expect(find.byType(FushiExpressiveLoadingIndicator), findsOneWidget);
    expect(find.byType(FushiWavyCircularProgress), findsNothing);
    expect(find.textContaining('MiB'), findsOneWidget);
  });

  testWidgets('只有字节和总大小时按字节推出百分比', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(
        value: null,
        receivedBytes: 250,
        totalBytes: 1000,
      ),
    );
    expect(find.text('25%'), findsOneWidget);
  });

  testWidgets('Apple：iOS 细圆环，不用波浪', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(value: 0.42),
      glass: true,
    );
    expect(find.byType(FushiAppleProgressRing), findsOneWidget);
    expect(find.byType(FushiWavyCircularProgress), findsNothing);
    expect(find.text('42%'), findsOneWidget);
  });

  testWidgets('Apple 不定态是菊花', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(value: null),
      glass: true,
    );
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
  });

  testWidgets('紧凑尺寸只显示数字', (WidgetTester tester) async {
    await _pump(
      tester,
      const Center(
        child: FushiDownloadProgressRing(
          value: 0.42,
          size: 28,
          color: Colors.white,
          trackColor: Colors.white24,
          labelColor: Colors.white,
        ),
      ),
    );
    expect(find.text('42'), findsOneWidget);
    expect(find.text('42%'), findsNothing);
  });

  testWidgets('下满 100% 淡出；减少动态效果时立即生效', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiDownloadCoverOverlay(value: 1),
      disableAnimations: true,
    );
    final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(fade.opacity, 0);
    expect(fade.duration, Duration.zero);
  });

  test('百分比向下取整，没真到 100 不显示 100', () {
    expect(fushiDownloadPercent(0.999), 99);
    expect(fushiDownloadPercent(1), 100);
    expect(fushiDownloadPercent(-1), 0);
  });
}
