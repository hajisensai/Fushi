import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/masked_illustration_cover.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;

/// BUG-2559：未解锁插图的遮罩强度必须与卡片尺寸挂钩。
///
/// 两个插图表面的缩略图不一样大——书架端插图库是最宽 200 的方卡、阅读器插图册是
/// 最宽 160 的 0.72 竖卡——两边却都写死 `sigma: 16`。同一个绝对模糊半径施在小
/// 20% 的卡上就是更糊一档，于是同一本书的同一张插图在两处看着不是一个遮罩。
/// 这里按短边取比例，让遮蔽力度与尺寸无关。
double _sigmaOf(WidgetTester tester) {
  final ImageFiltered filtered = tester.widget<ImageFiltered>(
    find.byType(ImageFiltered),
  );
  // ImageFilter.blur 的 toString 形如
  // `ImageFilter.blur(12.8, 12.8, clamp)`，sigma 只能从这里读出来。
  final Match? match = RegExp(
    r'blur\(([\d.]+), ([\d.]+)',
  ).firstMatch(filtered.imageFilter.toString());
  expect(match, isNotNull, reason: '遮罩必须是 ImageFilter.blur');
  final double x = double.parse(match!.group(1)!);
  final double y = double.parse(match.group(2)!);
  expect(x, y, reason: '两轴同一半径');
  return x;
}

Future<void> _pumpBox(WidgetTester tester, Size box, {double? sigma}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: box.width,
          height: box.height,
          child: Builder(
            builder: (BuildContext context) => maskedIllustrationCover(
              context,
              const ColoredBox(color: Color(0xFF884422)),
              sigma: sigma,
              iconSize: 32,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('模糊半径按卡片短边取比例，两种卡片尺寸下遮蔽力度一致', (
    WidgetTester tester,
  ) async {
    // 书架端插图库：200×200 方卡 → 历史上的 sigma 16，这次统一不改它的观感。
    await _pumpBox(tester, const Size(200, 200));
    expect(_sigmaOf(tester), closeTo(16, 0.001));

    // 阅读器插图册：160×222 竖卡 → 按短边 160 取同一比例。
    await _pumpBox(tester, const Size(160, 222));
    expect(
      _sigmaOf(tester),
      closeTo(160 * kMaskedIllustrationSigmaFraction, 0.001),
      reason: '窄卡不该因为写死 16 而更糊一档',
    );

    // 比例是同一个：两处的「模糊半径 ÷ 短边」相等，这才是「一致」的定义。
    await _pumpBox(tester, const Size(200, 200));
    final double wide = _sigmaOf(tester) / 200;
    await _pumpBox(tester, const Size(160, 222));
    final double narrow = _sigmaOf(tester) / 160;
    expect(wide, closeTo(narrow, 0.0001));
  });

  testWidgets('显式 sigma 仍然钉死绝对值（全屏查看器另配更重的蒙层）', (
    WidgetTester tester,
  ) async {
    await _pumpBox(tester, const Size(160, 222), sigma: 24);
    expect(_sigmaOf(tester), closeTo(24, 0.001));
  });

  testWidgets('遮罩盖住的是这张图本身，外加蒙层与图标', (WidgetTester tester) async {
    await _pumpBox(tester, const Size(160, 222));
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    // 模糊层外面套 ClipRect：高斯边缘不许糊到卡片外面去。
    expect(
      find.ancestor(
        of: find.byType(ImageFiltered),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
    );
  });

  testWidgets('墨水屏走实心遮板，一张糊图在灰阶上读不出「被盖住了」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const <ThemeExtension<dynamic>>[
            FushiEinkTheme(true),
          ],
        ),
        home: Center(
          child: SizedBox(
            width: 160,
            height: 222,
            child: Builder(
              builder: (BuildContext context) => maskedIllustrationCover(
                context,
                const ColoredBox(color: Color(0xFF884422)),
                iconSize: 32,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });
}
