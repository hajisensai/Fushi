import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/focus_geometry.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

void main() {
  const Size physicalView = Size(1000, 800);

  Widget appScaled({required double scale, required Widget child}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: FushiAppUiScale(scale: scale, child: child),
      );

  testWidgets('neutralizer restores real view size, MQ and reports scale 1.0', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    late Size gotMqSize;
    late double gotScale;

    await tester.pumpWidget(
      appScaled(
        scale: 2.0,
        child: FushiAppUiScaleNeutralizer(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              gotConstraintBiggest = c.biggest;
              gotMqSize = MediaQuery.of(context).size;
              gotScale = FushiAppUiScale.of(context);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    expect(gotConstraintBiggest, physicalView);
    expect(gotMqSize, physicalView);
    expect(gotScale, 1.0);
  });

  testWidgets('neutralizer is identity passthrough at scale 1.0', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = physicalView;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size gotConstraintBiggest;
    await tester.pumpWidget(
      appScaled(
        scale: 1.0,
        child: FushiAppUiScaleNeutralizer(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              gotConstraintBiggest = c.biggest;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    expect(gotConstraintBiggest, physicalView);
  });

  testWidgets('focus geometry under neutralizer == unscaled baseline', (
    WidgetTester tester,
  ) async {
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
    await tester.pumpWidget(
      appScaled(
        scale: 1.0,
        child: FushiAppUiScaleNeutralizer(child: probe(k1)),
      ),
    );
    final Rect baseline = globalRectOfBox(
      k1.currentContext!.findRenderObject()! as RenderBox,
    );

    final GlobalKey k2 = GlobalKey();
    await tester.pumpWidget(
      appScaled(
        scale: 2.0,
        child: FushiAppUiScaleNeutralizer(child: probe(k2)),
      ),
    );
    final Rect scaled = globalRectOfBox(
      k2.currentContext!.findRenderObject()! as RenderBox,
    );

    expect(scaled.left, closeTo(baseline.left, 0.5));
    expect(scaled.top, closeTo(baseline.top, 0.5));
    expect(scaled.width, closeTo(baseline.width, 0.5));
    expect(scaled.height, closeTo(baseline.height, 0.5));
  });

  // 路由层 FushiPageBackdrop → LibraryShapeBackdrop 是不带 fit 的 Stack，页面拿到的
  // 是宽松约束。中和层若不把自己钉成画布尺寸，RenderFittedBox 会缩成子树尺寸
  // （真实视口 = 画布 × s），界面缩放 < 1 时整页按 s 倍贴在左上角、外圈露出下层。
  for (final double scale in <double>[0.8, 0.9, 1.25]) {
    testWidgets('neutralizer under loose constraints still fills the window '
        '(scale $scale)', (WidgetTester tester) async {
      tester.view.physicalSize = physicalView;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final GlobalKey page = GlobalKey();
      await tester.pumpWidget(
        appScaled(
          scale: scale,
          child: Stack(
            children: <Widget>[
              FushiAppUiScaleNeutralizer(child: SizedBox.expand(key: page)),
            ],
          ),
        ),
      );

      final Rect rect = globalRectOfBox(
        page.currentContext!.findRenderObject()! as RenderBox,
      );
      expect(rect.left, closeTo(0, 0.5));
      expect(rect.top, closeTo(0, 0.5));
      expect(rect.width, closeTo(physicalView.width, 0.5));
      expect(rect.height, closeTo(physicalView.height, 0.5));
    });
  }

  // 真实路由链：界面缩放 → 路由层形状背景 → 阅读器入口的中和层（BUG 截图：阅读器 /
  // 歌词模式整页缩在左上角，外圈露出形状背景）。
  testWidgets(
    'page backdrop keeps the route constraints tight for the reader',
    (WidgetTester tester) async {
      tester.view.physicalSize = physicalView;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late BoxConstraints underBackdrop;
      final GlobalKey page = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: FushiAppUiScale(
            scale: 0.8,
            child: FushiPageBackdrop(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  underBackdrop = c;
                  return FushiAppUiScaleNeutralizer(
                    child: SizedBox.expand(key: page),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(underBackdrop.isTight, isTrue);
      final Rect rect = globalRectOfBox(
        page.currentContext!.findRenderObject()! as RenderBox,
      );
      expect(rect.width, closeTo(physicalView.width, 0.5));
      expect(rect.height, closeTo(physicalView.height, 0.5));
    },
  );
}
