import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_slim_progress_bar.dart';

void main() {
  group('videoSlimProgressFraction', () {
    test('正常换算', () {
      expect(videoSlimProgressFraction(positionMs: 0, durationMs: 1000), 0.0);
      expect(videoSlimProgressFraction(positionMs: 500, durationMs: 1000), 0.5);
      expect(
        videoSlimProgressFraction(positionMs: 1000, durationMs: 1000),
        1.0,
      );
    });

    test('未 load / 时长不可知一律 0', () {
      expect(
        videoSlimProgressFraction(positionMs: null, durationMs: 1000),
        0.0,
      );
      expect(videoSlimProgressFraction(positionMs: 500, durationMs: null), 0.0);
      // 直播流 duration 恒 0：不能除，也不能画成满格。
      expect(videoSlimProgressFraction(positionMs: 500, durationMs: 0), 0.0);
      expect(videoSlimProgressFraction(positionMs: 500, durationMs: -1), 0.0);
    });

    test('seek 在途越界被钳制（否则会画出超出轨道的线）', () {
      expect(
        videoSlimProgressFraction(positionMs: 1500, durationMs: 1000),
        1.0,
      );
      expect(videoSlimProgressFraction(positionMs: -20, durationMs: 1000), 0.0);
    });
  });

  group('VideoSlimProgressBar', () {
    double playedWidth(WidgetTester tester) => tester
        .getSize(
          find.descendant(
            of: find.byType(FractionallySizedBox),
            matching: find.byType(ColoredBox),
          ),
        )
        .width;

    testWidgets('按轮询推进已播段宽度', (WidgetTester tester) async {
      int position = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              child: VideoSlimProgressBar(
                positionMs: () => position,
                durationMs: () => 1000,
                color: const Color(0xFF00FF00),
                refreshInterval: const Duration(milliseconds: 50),
              ),
            ),
          ),
        ),
      );

      expect(playedWidth(tester), 0);

      position = 500;
      await tester.pump(const Duration(milliseconds: 60));
      expect(playedWidth(tester), 100);

      position = 1000;
      await tester.pump(const Duration(milliseconds: 60));
      expect(playedWidth(tester), 200);

      // 卸载必须停表，否则 pumpWidget 之后 timer 还在跑 → 框架报 pending timer。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('线高与已播比例照传，且不吃指针 / 不进语义树', (WidgetTester tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 100,
              child: VideoSlimProgressBar(
                positionMs: () => 250,
                durationMs: () => 1000,
                color: const Color(0xFFFF0000),
                height: 5,
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(VideoSlimProgressBar)).height, 5);
      expect(find.byType(IgnorePointer), findsOneWidget);
      expect(find.byType(ExcludeSemantics), findsOneWidget);
      expect(playedWidth(tester), 25);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('videoSlimProgressSeekFraction', () {
    test('按落点 / 宽度换算，越界钳制', () {
      expect(videoSlimProgressSeekFraction(dx: 0, width: 200), 0.0);
      expect(videoSlimProgressSeekFraction(dx: 50, width: 200), 0.25);
      expect(videoSlimProgressSeekFraction(dx: 200, width: 200), 1.0);
      expect(
        videoSlimProgressSeekFraction(dx: -20, width: 200),
        0.0,
        reason: '横拖会拖出左右边界，钳制而不是算出负数跳转',
      );
      expect(videoSlimProgressSeekFraction(dx: 260, width: 200), 1.0);
    });

    test('宽度不可用时返回 null（不是 0）', () {
      expect(
        videoSlimProgressSeekFraction(dx: 10, width: 0),
        isNull,
        reason: '首帧前 constraints 还没落定；返回 0 会把一次误触变成跳回片头',
      );
      expect(videoSlimProgressSeekFraction(dx: 10, width: -5), isNull);
      expect(videoSlimProgressSeekFraction(dx: 10, width: double.nan), isNull);
      expect(videoSlimProgressSeekFraction(dx: double.nan, width: 200), isNull);
    });
  });

  group('VideoSlimProgressBar 跳转', () {
    Widget host({
      required ValueChanged<double>? onSeekFraction,
      int position = 0,
    }) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 200,
          child: VideoSlimProgressBar(
            positionMs: () => position,
            durationMs: () => 1000,
            color: const Color(0xFF00FF00),
            onSeekFraction: onSeekFraction,
          ),
        ),
      ),
    );

    testWidgets('没有回调 = 纯装饰形态（逐像素与加手势前一致）', (WidgetTester tester) async {
      await tester.pumpWidget(host(onSeekFraction: null));
      expect(tester.getSize(find.byType(VideoSlimProgressBar)).height, 3);
      expect(
        find.byType(GestureDetector),
        findsNothing,
        reason: '沉浸锁 / 侧面板下调用方会传 null，那时细线一个指针都不许吃',
      );
      expect(find.byType(IgnorePointer), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('有回调时向上补一段命中带，可见线仍只有 3 像素', (WidgetTester tester) async {
      await tester.pumpWidget(host(onSeekFraction: (_) {}));
      expect(
        tester.getSize(find.byType(VideoSlimProgressBar)).height,
        12,
        reason: '3 像素的线鼠标瞄不准；命中带向上补到 hitTestHeight',
      );
      expect(
        tester.getSize(find.byType(FractionallySizedBox)).height,
        3,
        reason: '命中带是透明的，可见线不许跟着变粗',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('RTL 界面：填充仍从物理左端长，与点击换算同基准', (WidgetTester tester) async {
      final List<double> seeks = <double>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: SizedBox(
              width: 200,
              child: VideoSlimProgressBar(
                positionMs: () => 0,
                durationMs: () => 1000,
                color: const Color(0xFF00FF00),
                onSeekFraction: seeks.add,
              ),
            ),
          ),
        ),
      );
      final Offset topLeft = tester.getTopLeft(
        find.byType(VideoSlimProgressBar),
      );
      await tester.tapAt(topLeft + const Offset(150, 6));
      await tester.pump();
      expect(seeks, <double>[0.75]);
      final Finder fill = find.descendant(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(fill).width, 150);
      expect(
        tester.getTopLeft(fill).dx,
        topLeft.dx,
        reason: 'RTL 下若填充从右边长，点在可见端点处会跳到镜像位置',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('点击落点 → 对应比例，且线立即到位不等回读', (WidgetTester tester) async {
      final List<double> seeks = <double>[];
      await tester.pumpWidget(host(onSeekFraction: seeks.add));
      final Offset topLeft = tester.getTopLeft(
        find.byType(VideoSlimProgressBar),
      );
      await tester.tapAt(topLeft + const Offset(150, 6));
      await tester.pump();

      expect(seeks, <double>[0.75]);
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byType(FractionallySizedBox),
                matching: find.byType(ColoredBox),
              ),
            )
            .width,
        150,
        reason:
            '乐观到位：播放器 position 要等 seek 真落地才更新，不乐观的话线会先'
            '弹回原处再跳过去，看着像点歪了',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('横拖限频，但松手的终值一定送到', (WidgetTester tester) async {
      final List<double> seeks = <double>[];
      await tester.pumpWidget(host(onSeekFraction: seeks.add));
      final Offset topLeft = tester.getTopLeft(
        find.byType(VideoSlimProgressBar),
      );
      final TestGesture gesture = await tester.startGesture(
        topLeft + const Offset(20, 6),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump();

      expect(seeks, isNotEmpty);
      expect(
        seeks.last,
        closeTo(0.7, 0.001),
        reason:
            '限频可能吞掉最后一次采样；终值必须由 drag end 无条件补发，'
            '否则线停在手指处、播放位置停在上一次被放行的采样点',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
