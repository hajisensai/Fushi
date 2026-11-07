import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/baked_surface.dart';

/// [BakedSurface]：内容稳定后改画纹理、内容一变立刻回实时绘制，且像素与不烘焙
/// 一致。悬停 GPU 优化的正确性全靠这几条（纹理过时 = 卡片显示旧封面）。
void main() {
  RenderBakedSurface surfaceOf(WidgetTester tester) =>
      tester.renderObject<RenderBakedSurface>(find.byType(BakedSurface));

  /// 两帧：第一帧末看到实时绘制，再等一整帧无重绘才烘焙，烘焙后再画一帧纹理。
  Future<void> settleBake(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Widget host({required Widget child, GlobalKey? captureKey}) => Center(
    child: RepaintBoundary(
      key: captureKey,
      child: SizedBox(width: 60, height: 80, child: child),
    ),
  );

  Widget content(Color color) => ClipRRect(
    borderRadius: BorderRadius.circular(9),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[color, Colors.white.withValues(alpha: 0.3)],
        ),
      ),
    ),
  );

  Future<Uint8List> capture(WidgetTester tester, GlobalKey key) async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData bytes;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      bytes = (await image.toByteData())!;
      image.dispose();
    });
    return bytes.buffer.asUint8List();
  }

  /// 逐像素比较：报不同像素数与最大通道差（烘焙态与实时态应逐字节一致，
  /// 允许极少数抗锯齿边缘像素差 1）。
  void expectSamePixels(Uint8List actual, Uint8List expected, String why) {
    expect(actual.length, expected.length, reason: why);
    int differing = 0;
    int maxDelta = 0;
    for (int i = 0; i < actual.length; i++) {
      final int d = (actual[i] - expected[i]).abs();
      if (d > 0) differing++;
      if (d > maxDelta) maxDelta = d;
    }
    expect(
      maxDelta <= 1,
      isTrue,
      reason: '$why：$differing 个通道值不同，最大差 $maxDelta',
    );
  }

  testWidgets('static content bakes after it has been stable for a frame', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(child: BakedSurface(child: content(Colors.teal))),
    );
    expect(surfaceOf(tester).debugIsBaked, isFalse, reason: '首帧实时绘制');
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);
  });

  testWidgets('baked pixels match live rendering', (WidgetTester tester) async {
    final GlobalKey live = GlobalKey();
    await tester.pumpWidget(
      host(captureKey: live, child: content(Colors.teal)),
    );
    final Uint8List expected = await capture(tester, live);

    final GlobalKey baked = GlobalKey();
    await tester.pumpWidget(
      host(
        captureKey: baked,
        child: BakedSurface(child: content(Colors.teal)),
      ),
    );
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);
    expectSamePixels(await capture(tester, baked), expected, '烘焙态像素');
  });

  testWidgets('overflow keeps shadows painted outside the box', (
    WidgetTester tester,
  ) async {
    Widget shadowed() => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: Colors.teal,
        boxShadow: const <BoxShadow>[
          BoxShadow(blurRadius: 16, spreadRadius: -6, offset: Offset(0, 8)),
        ],
      ),
    );
    Widget frame({required GlobalKey key, required Widget child}) => Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 140,
          height: 160,
          child: Center(child: SizedBox(width: 60, height: 80, child: child)),
        ),
      ),
    );
    final GlobalKey live = GlobalKey();
    await tester.pumpWidget(frame(key: live, child: shadowed()));
    final Uint8List expected = await capture(tester, live);

    final GlobalKey baked = GlobalKey();
    await tester.pumpWidget(
      frame(
        key: baked,
        child: BakedSurface(
          overflow: const EdgeInsets.fromLTRB(30, 30, 30, 40),
          child: shadowed(),
        ),
      ),
    );
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);
    expectSamePixels(await capture(tester, baked), expected, '框外投影');
  });

  testWidgets('content change drops the bake at once and re-bakes later', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Color> color = ValueNotifier<Color>(Colors.teal);
    addTearDown(color.dispose);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        captureKey: key,
        child: BakedSurface(
          child: ValueListenableBuilder<Color>(
            valueListenable: color,
            builder: (BuildContext context, Color c, Widget? _) => content(c),
          ),
        ),
      ),
    );
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);

    color.value = Colors.orange;
    await tester.pump();
    expect(
      surfaceOf(tester).debugIsBaked,
      isFalse,
      reason: '内容变了的那一帧必须实时画新内容，不能显示旧纹理',
    );
    final Uint8List changed = await capture(tester, key);

    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);
    expectSamePixels(await capture(tester, key), changed, '重新烘焙的是新内容');
  });

  testWidgets('change right after baking still shows the new content', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Color> color = ValueNotifier<Color>(Colors.teal);
    addTearDown(color.dispose);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        captureKey: key,
        child: BakedSurface(
          child: ValueListenableBuilder<Color>(
            valueListenable: color,
            builder: (BuildContext context, Color c, Widget? _) => content(c),
          ),
        ),
      ),
    );
    // 推到「刚烘焙、还没改画纹理」的那一刻：首帧实时，第二帧末确认稳定后烘焙。
    await tester.pump();
    final bool justBaked = surfaceOf(tester).debugIsBaked;
    color.value = Colors.orange;
    await tester.pump();
    expect(justBaked, isTrue, reason: '前置条件：刚烘焙完');
    expect(surfaceOf(tester).debugIsBaked, isFalse);

    final GlobalKey reference = GlobalKey();
    await tester.pumpWidget(
      host(captureKey: reference, child: content(Colors.orange)),
    );
    final Uint8List expected = await capture(tester, reference);
    await tester.pumpWidget(
      host(
        captureKey: key,
        child: BakedSurface(child: content(Colors.orange)),
      ),
    );
    await settleBake(tester);
    expectSamePixels(await capture(tester, key), expected, '新内容');
  });

  testWidgets('continuously animating content stays live', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(child: const BakedSurface(child: CircularProgressIndicator())),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(surfaceOf(tester).debugIsBaked, isFalse);
    }
  });

  testWidgets('fractional on-screen offset stays pixel-identical', (
    WidgetTester tester,
  ) async {
    Widget frame({required GlobalKey key, required Widget child}) => Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 80,
          height: 100,
          child: Padding(
            padding: const EdgeInsets.only(left: 7.37, top: 3.71),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 60, height: 80, child: child),
            ),
          ),
        ),
      ),
    );
    final GlobalKey live = GlobalKey();
    await tester.pumpWidget(frame(key: live, child: content(Colors.teal)));
    final Uint8List expected = await capture(tester, live);

    final GlobalKey baked = GlobalKey();
    await tester.pumpWidget(
      frame(
        key: baked,
        child: BakedSurface(child: content(Colors.teal)),
      ),
    );
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue);
    expectSamePixels(await capture(tester, baked), expected, '亚像素位置');
  });

  testWidgets(
    'sub-pixel move drops the bake; whole-pixel move or rotation keeps it',
    (WidgetTester tester) async {
      final ValueNotifier<Matrix4> transform = ValueNotifier<Matrix4>(
        Matrix4.identity(),
      );
      addTearDown(transform.dispose);
      await tester.pumpWidget(
        host(
          child: ValueListenableBuilder<Matrix4>(
            valueListenable: transform,
            builder: (BuildContext context, Matrix4 m, Widget? child) =>
                Transform(transform: m, child: child),
            child: BakedSurface(child: content(Colors.teal)),
          ),
        ),
      );
      await settleBake(tester);
      expect(surfaceOf(tester).debugIsBaked, isTrue);

      // 整数个物理像素的平移：纹理照样 1:1 贴。
      final double px = 1 / tester.view.devicePixelRatio;
      transform.value = Matrix4.translationValues(5 * px, -2 * px, 0);
      await tester.pump();
      await tester.pump();
      expect(surfaceOf(tester).debugIsBaked, isTrue, reason: '整像素平移不必重画');

      // 亚像素平移：贴图会重采样，必须回实时绘制。
      transform.value = Matrix4.translationValues(5.5 * px, 0, 0);
      await tester.pump();
      await tester.pump();
      expect(surfaceOf(tester).debugIsBaked, isFalse, reason: '亚像素平移');
      await settleBake(tester);
      expect(surfaceOf(tester).debugIsBaked, isTrue, reason: '停稳后重新烘焙');

      // 旋转（扇形后层常驻旋转 / 悬停 3D 倾斜同类，BUG-4222）：不可能 1:1 贴图，
      // 但内容没变、放大倍数没超过纹理分辨率，就一直贴纹理，不回实时栅格化。
      final double dpr = tester.view.devicePixelRatio;
      for (int i = 0; i < 4; i++) {
        transform.value = Matrix4.rotationZ(0.05 * (i + 1));
        await tester.pump();
        expect(surfaceOf(tester).debugIsBaked, isTrue, reason: '旋转中第 $i 帧');
      }

      // 旋转 + 放大超过纹理分辨率：回实时绘制，停稳后按更高分辨率重烘（不把
      // 小纹理放大糊掉）。
      transform.value = Matrix4.rotationZ(0.05)..scaleByDouble(1.1, 1.1, 1, 1);
      await tester.pump();
      await tester.pump();
      expect(surfaceOf(tester).debugIsBaked, isFalse, reason: '放大超过纹理分辨率');
      await settleBake(tester);
      expect(surfaceOf(tester).debugIsBaked, isTrue, reason: '放大后重烘');
      expect(
        surfaceOf(tester).debugBakedPixelRatio,
        greaterThanOrEqualTo(dpr * 1.1),
      );

      // 回到轴对齐：重采样纹理不能 1:1，回实时绘制后重烘一张 1:1 的。
      transform.value = Matrix4.identity();
      await tester.pump();
      await tester.pump();
      expect(surfaceOf(tester).debugIsBaked, isFalse, reason: '回轴对齐先实时画');
      await settleBake(tester);
      expect(surfaceOf(tester).debugIsBaked, isTrue);
      expect(surfaceOf(tester).debugBakedPixelRatio, dpr, reason: '1:1 纹理');
    },
  );

  testWidgets('rotated surface bakes and looks like live rendering', (
    WidgetTester tester,
  ) async {
    Widget rotated({required GlobalKey key, required Widget child}) => host(
      captureKey: key,
      child: Transform.rotate(angle: -0.11, child: child),
    );
    final GlobalKey live = GlobalKey();
    await tester.pumpWidget(rotated(key: live, child: content(Colors.teal)));
    final Uint8List expected = await capture(tester, live);

    final GlobalKey baked = GlobalKey();
    await tester.pumpWidget(
      rotated(
        key: baked,
        child: BakedSurface(child: content(Colors.teal)),
      ),
    );
    expect(surfaceOf(tester).debugIsBaked, isFalse, reason: '首帧实时绘制');
    await settleBake(tester);
    expect(surfaceOf(tester).debugIsBaked, isTrue, reason: '旋转中照样烘焙');
    final Uint8List actual = await capture(tester, baked);
    // 重采样纹理不是逐字节一致：斜边抗锯齿与双线性各差一点，但整体不能走样。
    expect(actual.length, expected.length);
    int total = 0;
    int far = 0;
    for (int i = 0; i < actual.length; i++) {
      final int d = (actual[i] - expected[i]).abs();
      total += d;
      if (d > 48) far++;
    }
    final double mean = total / actual.length;
    expect(mean, lessThan(1.5), reason: '平均通道差 $mean');
    expect(
      far / actual.length,
      lessThan(0.01),
      reason: '差异大的通道占比 ${far / actual.length}（只允许斜边几像素）',
    );
  });

  testWidgets('nested repaint boundary is never baked', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        child: BakedSurface(
          child: RepaintBoundary(child: content(Colors.teal)),
        ),
      ),
    );
    await settleBake(tester);
    expect(
      surfaceOf(tester).debugIsBaked,
      isFalse,
      reason: '嵌套 boundary 重绘不会通知到本节点，烘焙了就会过时',
    );
  });
}
