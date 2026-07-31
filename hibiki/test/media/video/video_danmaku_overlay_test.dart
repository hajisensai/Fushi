import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_overlay.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 200, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('VideoDanmakuOverlay is IgnorePointer and caps rendered widgets',
      (WidgetTester tester) async {
    int positionMs = 1000;
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[
          _item(0, 'first'),
          _item(10, 'second'),
        ],
        enabled: true,
        maxActive: 1,
        positionMs: () => positionMs,
      ),
    );

    final IgnorePointer ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(const Key('video-danmaku-ignore-pointer')),
    );
    expect(ignorePointer.ignoring, isTrue);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing,
        reason: 'maxActive should cap render count before widgets are built');

    positionMs = 10000;
    await tester.pump();
    expect(find.text('first'), findsNothing,
        reason: 'seek/tick rebuild must not keep stale active comments');
  });

  testWidgets('disabled overlay renders nothing but keeps pointer passthrough',
      (WidgetTester tester) async {
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'hidden')],
        enabled: false,
        maxActive: 20,
        positionMs: () => 1000,
      ),
    );

    final IgnorePointer ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(const Key('video-danmaku-ignore-pointer')),
    );
    expect(ignorePointer.ignoring, isTrue);
    expect(find.text('hidden'), findsNothing);
  });

  testWidgets('disabled or empty overlay does not keep a frame ticker alive',
      (WidgetTester tester) async {
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'hidden')],
        enabled: false,
        maxActive: 20,
        positionMs: () => 1000,
      ),
    );

    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(milliseconds: 120),
    );

    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: const <VideoDanmakuItem>[],
        enabled: true,
        maxActive: 20,
        positionMs: () => 1000,
      ),
    );

    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(milliseconds: 120),
    );
  });

  double scrollLeft(WidgetTester tester, String text) => tester
      .widget<Positioned>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Positioned))
            .first,
      )
      .left!;

  testWidgets(
      'scroll danmaku interpolates between low-frequency position samples',
      (WidgetTester tester) async {
    // 播放器时钟固定不动（模拟 media_kit state.position ~200ms 才更新的那段间隙），
    // 但时间在推进 + 正在播放：插值必须让滚动弹幕继续左移，而不是卡住等下次采样。
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'x')],
        enabled: true,
        maxActive: 20,
        positionMs: () => 2000,
        isPlaying: () => true,
        speed: () => 1.0,
      ),
    );

    final double before = scrollLeft(tester, 'x');
    await tester.pump(const Duration(milliseconds: 50));
    final double after = scrollLeft(tester, 'x');

    expect(after, lessThan(before),
        reason: '真值未更新的帧里，插值让滚动弹幕平滑左移（消除 ~200ms 跳格）');
  });

  testWidgets('paused danmaku freezes (no extrapolation drift)',
      (WidgetTester tester) async {
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'x')],
        enabled: true,
        maxActive: 20,
        positionMs: () => 2000,
        isPlaying: () => false,
        speed: () => 1.0,
      ),
    );

    final double before = scrollLeft(tester, 'x');
    await tester.pump(const Duration(milliseconds: 200));
    final double after = scrollLeft(tester, 'x');

    expect(after, before, reason: '暂停时插值冻结在真值，弹幕不应继续漂移');
  });

  testWidgets('speed scales interpolation (2x drifts ~twice as far)',
      (WidgetTester tester) async {
    Future<double> travel(double speed) async {
      await _pump(
        tester,
        VideoDanmakuOverlay(
          items: <VideoDanmakuItem>[_item(0, 'x')],
          enabled: true,
          maxActive: 20,
          positionMs: () => 2000,
          isPlaying: () => true,
          speed: () => speed,
        ),
      );
      final double before = scrollLeft(tester, 'x');
      await tester.pump(const Duration(milliseconds: 60));
      final double after = scrollLeft(tester, 'x');
      return before - after; // 左移距离（正数）
    }

    final double at1x = await travel(1.0);
    final double at2x = await travel(2.0);
    expect(at2x, greaterThan(at1x), reason: '倍速时按帧外推更快，弹幕单帧左移更远');
  });

  testWidgets('scroll danmaku is monotonic: backward raw jitter never reverses',
      (WidgetTester tester) async {
    // media_kit `state.position` 偶发小幅回退时，弹幕绝不能往右跳回——否则退出边缘
    // 会来回穿越活动/淡出阈值，表现为「来回跳动 + 忽隐忽现」。
    int raw = 2000;
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'x')],
        enabled: true,
        maxActive: 20,
        positionMs: () => raw,
        isPlaying: () => true,
        speed: () => 1.0,
      ),
    );

    final double l0 = scrollLeft(tester, 'x');
    await tester.pump(const Duration(milliseconds: 100));
    final double l1 = scrollLeft(tester, 'x');
    expect(l1, lessThan(l0), reason: '正常播放时滚动弹幕左移');

    raw = 1950; // 播放器时钟小幅回退（<1s，非 seek）
    await tester.pump(const Duration(milliseconds: 16));
    final double l2 = scrollLeft(tester, 'x');
    expect(l2, lessThanOrEqualTo(l1), reason: 'raw 小幅回退时弹幕只进不退（消除来回跳动）');
  });

  testWidgets('scroll danmaku has left the viewport on its last rendered frame',
      (WidgetTester tester) async {
    // BUG-1297：在**真实渲染宽度**上验证退场——弹幕停止渲染的那一帧，它的文本框
    // 必须已经整体越过视口左边界，而不是右半截还挂在画面里被整条抹掉。
    const String text = 'とても長いコメントですとても長いコメントです';
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, text)],
        enabled: true,
        maxActive: 20,
        // 暂停：插值冻结在真值，几何完全由 positionMs 决定。
        positionMs: () => 8000,
        isPlaying: () => false,
        speed: () => 1.0,
      ),
    );

    final Rect viewport = tester.getRect(find.byType(VideoDanmakuOverlay));
    final Rect rendered = tester.getRect(find.text(text));
    expect(
      rendered.right,
      lessThanOrEqualTo(viewport.left + 0.01),
      reason: '最后一帧文本右边缘应已越过视口左边界，下一帧移出活动集才不会突兀',
    );
  });

  testWidgets('scroll danmaku stays fully opaque all the way out',
      (WidgetTester tester) async {
    Future<double> opacityAt(int positionMs) async {
      await _pump(
        tester,
        VideoDanmakuOverlay(
          items: <VideoDanmakuItem>[_item(0, 'コメント')],
          enabled: true,
          maxActive: 20,
          positionMs: () => positionMs,
          isPlaying: () => false,
          speed: () => 1.0,
        ),
      );
      return tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('コメント'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
    }

    expect(await opacityAt(4000), 1.0);
    expect(await opacityAt(7600), 1.0, reason: '旧实现在此处已开始渐隐（progress>0.88）');
    expect(await opacityAt(8000), 1.0, reason: '退场靠位移，不靠渐隐');
  });

  testWidgets('large backward raw (seek) re-aligns danmaku position',
      (WidgetTester tester) async {
    int raw = 6000;
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'x')],
        enabled: true,
        maxActive: 20,
        positionMs: () => raw,
        isPlaying: () => true,
        speed: () => 1.0,
      ),
    );
    final double before = scrollLeft(tester, 'x');
    // 真正 seek 回退（>1s）：弹幕应对齐到新位置（更靠右，progress 变小）。
    raw = 1000;
    await tester.pump(const Duration(milliseconds: 16));
    final double after = scrollLeft(tester, 'x');
    expect(after, greaterThan(before), reason: 'seek 回退是真正的位置跳变，弹幕对齐真值（更靠右）');
  });
}
