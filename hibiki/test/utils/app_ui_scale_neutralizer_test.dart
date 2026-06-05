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

  group('scaledRectToCanvas', () {
    // 视频查词浮层定位修复：把 localToGlobal（缩放后屏幕坐标）的字符 rect 换算回
    // HibikiAppUiScale 的逻辑画布坐标系（= 根 Overlay / calcPopupPosition 的 screen）。
    const Rect raw = Rect.fromLTWH(300, 200, 40, 50);

    test('scale 1.0 is identity passthrough', () {
      expect(scaledRectToCanvas(raw, 1.0), raw);
    });

    test('scale 1.5 divides every edge by the scale', () {
      final Rect got = scaledRectToCanvas(raw, 1.5);
      expect(got.left, closeTo(300 / 1.5, 1e-9));
      expect(got.top, closeTo(200 / 1.5, 1e-9));
      expect(got.width, closeTo(40 / 1.5, 1e-9));
      expect(got.height, closeTo(50 / 1.5, 1e-9));
    });

    test('scale 0.8 maps the shrunk-screen rect back up to the canvas', () {
      final Rect got = scaledRectToCanvas(raw, 0.8);
      expect(got.left, closeTo(300 / 0.8, 1e-9));
      expect(got.top, closeTo(200 / 0.8, 1e-9));
      expect(got.width, closeTo(40 / 0.8, 1e-9));
      expect(got.height, closeTo(50 / 0.8, 1e-9));
    });

    test('round-trips against the FittedBox scaling localToGlobal applies', () {
      // FittedBox maps canvas→screen by ×s, so a box laid out at canvas point p
      // reports localToGlobal == p×s. scaledRectToCanvas must invert that back
      // to p exactly, so the char rect lands in the popup/overlay coord space.
      const Rect canvasRect = Rect.fromLTWH(120, 80, 30, 30);
      for (final double s in <double>[0.5, 0.8, 1.0, 1.5, 2.0, 3.0]) {
        final Rect scaledScreenRect = Rect.fromLTRB(
          canvasRect.left * s,
          canvasRect.top * s,
          canvasRect.right * s,
          canvasRect.bottom * s,
        );
        final Rect back = scaledRectToCanvas(scaledScreenRect, s);
        expect(back.left, closeTo(canvasRect.left, 1e-6));
        expect(back.top, closeTo(canvasRect.top, 1e-6));
        expect(back.width, closeTo(canvasRect.width, 1e-6));
        expect(back.height, closeTo(canvasRect.height, 1e-6));
      }
    });

    test('clamps out-of-range scale via HibikiAppUiScale.normalize', () {
      // normalize clamps to [0.3, 3.0]; 0.0 / NaN must not divide-by-zero.
      expect(scaledRectToCanvas(raw, 0.0).isFinite, isTrue);
      expect(scaledRectToCanvas(raw, double.nan), raw); // NaN→default 1.0
      final Rect huge = scaledRectToCanvas(raw, 99.0); // →3.0
      expect(huge.left, closeTo(300 / 3.0, 1e-9));
    });
  });
}
