import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

void main() {
  const Size physicalView = Size(1000, 800);

  Widget appScaled({required double scale, required Widget child}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: HibikiAppUiScale(scale: scale, child: child),
      );

  testWidgets('neutralizer restores real view size, MQ and reports scale 1.0',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    late Size gotMqSize;
    late double gotScale;

    await tester.pumpWidget(appScaled(
      scale: 2.0,
      child: HibikiAppUiScaleNeutralizer(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            gotConstraintBiggest = c.biggest;
            gotMqSize = MediaQuery.of(context).size;
            gotScale = HibikiAppUiScale.of(context);
            return const SizedBox.expand();
          },
        ),
      ),
    ));

    expect(gotConstraintBiggest, physicalView);
    expect(gotMqSize, physicalView);
    expect(gotScale, 1.0);
  });

  testWidgets('neutralizer is identity passthrough at scale 1.0',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    await tester.pumpWidget(appScaled(
      scale: 1.0,
      child: HibikiAppUiScaleNeutralizer(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            gotConstraintBiggest = c.biggest;
            return const SizedBox.expand();
          },
        ),
      ),
    ));
    expect(gotConstraintBiggest, physicalView);
  });

  testWidgets('focus geometry under neutralizer == unscaled baseline',
      (WidgetTester tester) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget probe(GlobalKey key) => Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 120, top: 90),
            child: SizedBox(key: key, width: 200, height: 60),
          ),
        );

    final GlobalKey k1 = GlobalKey();
    await tester.pumpWidget(appScaled(
      scale: 1.0,
      child: HibikiAppUiScaleNeutralizer(child: probe(k1)),
    ));
    final Rect baseline =
        globalRectOfBox(k1.currentContext!.findRenderObject()! as RenderBox);

    final GlobalKey k2 = GlobalKey();
    await tester.pumpWidget(appScaled(
      scale: 2.0,
      child: HibikiAppUiScaleNeutralizer(child: probe(k2)),
    ));
    final Rect scaled =
        globalRectOfBox(k2.currentContext!.findRenderObject()! as RenderBox);

    expect(scaled.left, closeTo(baseline.left, 0.5));
    expect(scaled.top, closeTo(baseline.top, 0.5));
    expect(scaled.width, closeTo(baseline.width, 0.5));
    expect(scaled.height, closeTo(baseline.height, 0.5));
  });
}
