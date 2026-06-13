import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/spacing.dart';

void main() {
  group('automatic UI scale calculation', () {
    test('defaults to phone-sized scale on a regular mobile viewport', () {
      final double scale = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(390, 844),
        platform: TargetPlatform.android,
      );

      expect(scale, closeTo(1.0, 0.001));
    });

    test('shrinks cramped mobile viewports but grows tablet viewports', () {
      final double smallPhone = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(320, 568),
        platform: TargetPlatform.android,
      );
      final double tablet = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(768, 1024),
        platform: TargetPlatform.android,
      );

      expect(smallPhone, lessThan(1.0));
      expect(smallPhone, greaterThanOrEqualTo(0.92));
      expect(tablet, greaterThan(1.0));
      expect(tablet, lessThanOrEqualTo(1.12));
    });

    test('uses desktop window size as a continuous input', () {
      final double compactWindow = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(800, 600),
        platform: TargetPlatform.windows,
      );
      final double fullHdWindow = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(1920, 1080),
        platform: TargetPlatform.windows,
      );
      final double largeWindow = HibikiAppUiScale.automaticScaleForViewport(
        viewport: const Size(3840, 2160),
        platform: TargetPlatform.windows,
      );

      expect(compactWindow, lessThan(1.0));
      expect(fullHdWindow, greaterThan(1.0));
      expect(largeWindow, greaterThan(fullHdWindow));
      expect(largeWindow, lessThanOrEqualTo(1.16));
    });

    test('falls back to defaultScale for invalid viewport sizes', () {
      expect(
        HibikiAppUiScale.automaticScaleForViewport(
          viewport: Size.zero,
          platform: TargetPlatform.android,
        ),
        HibikiAppUiScale.defaultScale,
      );
      expect(
        HibikiAppUiScale.automaticScaleForViewport(
          viewport: const Size(double.nan, 800),
          platform: TargetPlatform.windows,
        ),
        HibikiAppUiScale.defaultScale,
      );
    });
  });

  testWidgets('整体缩放：固定尺寸子节点视觉尺寸按 scale 放大', (
    WidgetTester tester,
  ) async {
    const Key boxKey = Key('scaled-box');
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
            scale: 2.0, child: child ?? const SizedBox.shrink()),
        home: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: boxKey,
            width: 100,
            height: 100,
            child: ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      ),
    );

    final Size logical = tester.getSize(find.byKey(boxKey));
    final Rect visual = tester.getRect(find.byKey(boxKey));
    expect(logical.width, 100);
    expect(visual.width, 200);
    expect(visual.height, 200);
  });

  testWidgets('整体缩放：间距基数保持 10（视觉由 Transform 放大，不再二次乘 scale）', (
    WidgetTester tester,
  ) async {
    late double normalSpacing;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
            scale: 3.0, child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (BuildContext context) {
            normalSpacing = Spacing.of(context).spaces.normal;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(normalSpacing, 10.0);
  });

  testWidgets('整体缩放：不再改写 textScaler（系统字号缩放原样透传）', (
    WidgetTester tester,
  ) async {
    late double textScale;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.2)),
          child: HibikiAppUiScale(
              scale: 2.0, child: child ?? const SizedBox.shrink()),
        ),
        home: Builder(
          builder: (BuildContext context) {
            textScale = MediaQuery.textScalerOf(context).scale(1);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(textScale, closeTo(1.2, 0.001));
  });

  testWidgets('缩小 (scale<1)：屏幕底部按钮仍可命中点击（无 OverflowBox 死区）', (
    WidgetTester tester,
  ) async {
    bool bottomTapped = false;
    bool topTapped = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
            scale: 0.5, child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 80,
                  height: 40,
                  child: GestureDetector(
                    onTap: () => topTapped = true,
                    child: const ColoredBox(color: Color(0xFF0000FF)),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 120,
                  height: 48,
                  child: GestureDetector(
                    onTap: () => bottomTapped = true,
                    child: const ColoredBox(color: Color(0xFFFF0000)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first); // top-left
    await tester.tap(find.byType(GestureDetector).last); // bottom-center
    await tester.pump();

    expect(topTapped, isTrue, reason: '左上控件应可点击');
    expect(bottomTapped, isTrue, reason: '缩小后底栏控件不应落入命中死区');
  });

  testWidgets('scale==1.0 走快路径：不插入 Transform，无额外变换', (
    WidgetTester tester,
  ) async {
    const Key boxKey = Key('unscaled-box');
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
            scale: 1.0, child: child ?? const SizedBox.shrink()),
        home: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: boxKey,
            width: 100,
            height: 100,
            child: ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      ),
    );
    final Rect visual = tester.getRect(find.byKey(boxKey));
    expect(visual.width, 100);
  });
}
