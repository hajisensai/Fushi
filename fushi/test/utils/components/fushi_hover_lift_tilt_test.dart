import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_hover_lift.dart';

/// 3D 倾斜视差（[FushiTilt]）按**自己的盒子**判指针在哪一侧，不按整张卡：
/// 封面只占宽卡起始侧一小块时，指针停在封面右缘，封面要朝右按下去
/// （用户 2026-11-03 截图：此前按整卡归一化，封面右缘仍算「卡左半边」，朝左偏）。
void main() {
  const double coverWidth = 100;
  const double cardWidth = 600;
  const double height = 100;

  Future<TestGesture> hoverAt(WidgetTester tester, Offset at) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: FushiHoverLift(
              builder: (BuildContext _, bool __) => const SizedBox(
                width: cardWidth,
                height: height,
                child: Row(
                  children: <Widget>[
                    FushiTilt(
                      child: SizedBox(width: coverWidth, height: height),
                    ),
                    Expanded(child: SizedBox(height: height)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(790, 390));
    await tester.pump();
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    return mouse;
  }

  /// 倾斜层的 rotateY 角的正弦（矩阵 (0,2) 项）：< 0 = 右侧按下去（朝右）。
  double tiltSinY(WidgetTester tester) => tester
      .widget<Transform>(
        find
            .descendant(
              of: find.byType(FushiTilt),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform
      .entry(0, 2);

  const double maxRad = kFushiTiltMaxDegrees * math.pi / 180;

  testWidgets('指针停在封面右缘（整卡左半边）：封面朝右倾', (WidgetTester tester) async {
    // 卡片中心在 300：x=90 落在整卡左侧，但在封面（0..100）右缘附近。
    await hoverAt(tester, const Offset(90, height / 2));
    expect(tiltSinY(tester), lessThan(-math.sin(maxRad * 0.5)));
  });

  testWidgets('指针停在封面左缘：封面朝左倾', (WidgetTester tester) async {
    await hoverAt(tester, const Offset(10, height / 2));
    expect(tiltSinY(tester), greaterThan(math.sin(maxRad * 0.5)));
  });

  testWidgets('指针在封面外的信息列上：封面朝指针那侧倾到底', (WidgetTester tester) async {
    await hoverAt(tester, const Offset(500, height / 2));
    expect(tiltSinY(tester), closeTo(-math.sin(maxRad), 1e-6));
  });

  testWidgets('移出卡片：倾斜缓回平面', (WidgetTester tester) async {
    final TestGesture mouse = await hoverAt(
      tester,
      const Offset(90, height / 2),
    );
    await mouse.moveTo(const Offset(790, 390));
    await tester.pumpAndSettle();
    expect(tiltSinY(tester), closeTo(0, 1e-9));
  });
}
