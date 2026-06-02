import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/spacing.dart';

void main() {
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

  testWidgets('HibikiNativeScale：缩放 2.0 下宿主子节点净变换为单位阵（按原生逻辑分辨率布局、填满区域）', (
    WidgetTester tester,
  ) async {
    const Key hostChildKey = Key('native-child');
    late Size childLogicalSize;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
            scale: 2.0, child: child ?? const SizedBox.shrink()),
        home: HibikiNativeScale(
          child: Builder(
            builder: (BuildContext context) {
              childLogicalSize = MediaQuery.of(context).size;
              return const ColoredBox(
                key: hostChildKey,
                color: Color(0xFF112233),
                child: SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    );

    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(childLogicalSize.width, closeTo(screen.width, 0.5));
    expect(childLogicalSize.height, closeTo(screen.height, 0.5));
    final Rect visual = tester.getRect(find.byKey(hostChildKey));
    expect(visual.width, closeTo(screen.width, 0.5));
    expect(visual.height, closeTo(screen.height, 0.5));
  });
}
