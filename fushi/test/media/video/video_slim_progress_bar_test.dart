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
}
