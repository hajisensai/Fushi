import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

void main() {
  // 根因回归：Material [Slider] 的值指示器水平钳制（getHorizontalShift）用
  // parentBox.localToGlobal(center) 取 GLOBAL/view 坐标，再与 sizeWithOverflow
  // (= MediaQuery.sizeOf) 比较，SDK 假定两者同空间。HibikiAppUiScale 把整棵树
  // Transform.scale(s) 放大、同时把 MediaQuery.size 缩成 view/s，导致两者差 s²，
  // 钳制算出巨大负 shift，把「220%」气泡甩到拇指左侧、压住描述文字。
  //
  // 契约：adaptiveSlider 必须让 Slider 自身看到的 screenSize 回到 GLOBAL/view 空间
  // (= MediaQuery.size * scale)，与 localToGlobal 同空间，钳制才正确归零。
  testWidgets('UI scale 下 adaptiveSlider 的 screenSize 回到 GLOBAL/view 空间', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
          scale: 2.0,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => adaptiveSlider(
              context: context,
              value: 0.5,
              min: 0,
              max: 1,
              label: '50%',
              onChanged: (double _) {},
            ),
          ),
        ),
      ),
    );

    // Slider 自身 context 解析到的 MediaQuery.size 应为 GLOBAL/view 宽度 900，
    // 而非 HibikiAppUiScale 缩小后的逻辑画布 450。
    final Element sliderEl = tester.element(find.byType(Slider));
    final Size sliderScreenSize = MediaQuery.sizeOf(sliderEl);
    expect(sliderScreenSize.width, closeTo(900, 0.5));
    expect(sliderScreenSize.height, closeTo(600, 0.5));
  });

  testWidgets('scale==1.0：adaptiveSlider 不改写 screenSize（无额外 MediaQuery）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => HibikiAppUiScale(
          scale: 1.0,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => adaptiveSlider(
              context: context,
              value: 0.5,
              min: 0,
              max: 1,
              label: '50%',
              onChanged: (double _) {},
            ),
          ),
        ),
      ),
    );

    final Element sliderEl = tester.element(find.byType(Slider));
    final Size sliderScreenSize = MediaQuery.sizeOf(sliderEl);
    expect(sliderScreenSize.width, closeTo(900, 0.5));
    expect(sliderScreenSize.height, closeTo(600, 0.5));
  });
}
