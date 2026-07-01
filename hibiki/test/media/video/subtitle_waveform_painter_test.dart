import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';

/// TODO-1051 阶段B：波形 painter 的纯几何函数 + 渲染守卫单测。
void main() {
  group('waveformBucketRect (TODO-1051 stageB)', () {
    const Size size = Size(300, 100);
    const double centerY = 50;

    test('degenerate returns Rect.zero', () {
      expect(
        waveformBucketRect(
          bucketIndex: 0,
          bucketCount: 0,
          value: 1,
          size: size,
          centerY: centerY,
        ),
        Rect.zero,
      );
      expect(
        waveformBucketRect(
          bucketIndex: 0,
          bucketCount: 4,
          value: 1,
          size: const Size(0, 100),
          centerY: centerY,
        ),
        Rect.zero,
      );
      expect(
        waveformBucketRect(
          bucketIndex: 5,
          bucketCount: 4,
          value: 1,
          size: size,
          centerY: centerY,
        ),
        Rect.zero,
      );
    });

    test('buckets evenly split width; bar symmetric about center', () {
      final Rect r = waveformBucketRect(
        bucketIndex: 0,
        bucketCount: 4,
        value: 1.0,
        size: size,
        centerY: centerY,
        gap: 0,
        verticalPadding: 0,
      );
      expect(r.left, closeTo(0, 0.001));
      expect(r.right, closeTo(75, 0.001));
      expect(r.top, closeTo(0, 0.001));
      expect(r.bottom, closeTo(100, 0.001));
      expect(centerY - r.top, closeTo(r.bottom - centerY, 0.001));
    });

    test('value scales height; verticalPadding shrinks usable half', () {
      final Rect r = waveformBucketRect(
        bucketIndex: 1,
        bucketCount: 4,
        value: 0.5,
        size: size,
        centerY: centerY,
        gap: 0,
        verticalPadding: 10,
      );
      expect(r.top, closeTo(30, 0.001));
      expect(r.bottom, closeTo(70, 0.001));
    });

    test('value clamped to 0..1 (never exceeds box)', () {
      final Rect over = waveformBucketRect(
        bucketIndex: 0,
        bucketCount: 2,
        value: 5.0,
        size: size,
        centerY: centerY,
        gap: 0,
        verticalPadding: 0,
      );
      expect(over.top, closeTo(0, 0.001));
      expect(over.bottom, closeTo(100, 0.001));
    });

    test('gap narrows bar width from both sides, centered', () {
      final Rect r = waveformBucketRect(
        bucketIndex: 0,
        bucketCount: 4,
        value: 1,
        size: size,
        centerY: centerY,
        gap: 10,
      );
      expect(r.left, closeTo(5, 0.001));
      expect(r.width, closeTo(65, 0.001));
    });
  });

  group('timeToX (TODO-1051 stageB)', () {
    test('linear map time to x within window', () {
      expect(
        timeToX(timeMs: 5000, windowStartMs: 0, windowEndMs: 10000, width: 200),
        closeTo(100, 0.001),
      );
      expect(
        timeToX(timeMs: 0, windowStartMs: 0, windowEndMs: 10000, width: 200),
        closeTo(0, 0.001),
      );
      expect(
        timeToX(
            timeMs: 10000, windowStartMs: 0, windowEndMs: 10000, width: 200),
        closeTo(200, 0.001),
      );
    });

    test('non-zero window start offsets correctly', () {
      expect(
        timeToX(
            timeMs: 3000, windowStartMs: 2000, windowEndMs: 4000, width: 100),
        closeTo(50, 0.001),
      );
    });

    test('out-of-window time returns out-of-window x (no clamp)', () {
      final double x = timeToX(
          timeMs: -1000, windowStartMs: 0, windowEndMs: 10000, width: 200);
      expect(x, lessThan(0));
    });

    test('degenerate window / non-positive width returns NaN', () {
      expect(
        timeToX(timeMs: 100, windowStartMs: 500, windowEndMs: 500, width: 200)
            .isNaN,
        isTrue,
      );
      expect(
        timeToX(timeMs: 100, windowStartMs: 0, windowEndMs: 1000, width: 0)
            .isNaN,
        isTrue,
      );
    });
  });

  group('downsample -> painter contract', () {
    test('downsample output in 0..1, bucketRect never exceeds box', () {
      final List<double> raw = <double>[
        -60,
        -20,
        -40,
        -10,
        -80,
        -15,
        -30,
        -5,
      ];
      final List<double> buckets = downsampleEnergyEnvelope(raw, 4);
      expect(buckets.length, 4);
      for (final double v in buckets) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      const Size size = Size(200, 80);
      for (int i = 0; i < buckets.length; i++) {
        final Rect r = waveformBucketRect(
          bucketIndex: i,
          bucketCount: buckets.length,
          value: buckets[i],
          size: size,
          centerY: 40,
        );
        expect(r.top, greaterThanOrEqualTo(0));
        expect(r.bottom, lessThanOrEqualTo(80));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(200));
      }
    });
  });

  group('SubtitleWaveformPainter shouldRepaint', () {
    SubtitleWaveformPainter mk({
      List<double>? buckets,
      int previewDelayMs = 0,
      int currentPositionMs = 0,
    }) {
      return SubtitleWaveformPainter(
        buckets: buckets ?? <double>[0.1, 0.5, 0.9],
        windowStartMs: 0,
        windowEndMs: 10000,
        cueBoundariesMs: <int>[1000, 2000],
        previewDelayMs: previewDelayMs,
        currentPositionMs: currentPositionMs,
        waveColor: const Color(0xFF001122),
        cueLineColor: const Color(0xFF334455),
        playheadColor: const Color(0xFF667788),
        centerLineColor: const Color(0xFF99AABB),
      );
    }

    test('preview delay change => repaint', () {
      expect(
          mk(previewDelayMs: 0).shouldRepaint(mk(previewDelayMs: 500)), isTrue);
    });

    test('position change => repaint', () {
      expect(mk(currentPositionMs: 0).shouldRepaint(mk(currentPositionMs: 100)),
          isTrue);
    });

    test('identical => no repaint', () {
      expect(mk().shouldRepaint(mk()), isFalse);
    });
  });

  group('SubtitleWaveformPainter renders (widget)', () {
    testWidgets('with buckets => CustomPaint renders (no throw)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 100,
              child: CustomPaint(
                painter: SubtitleWaveformPainter(
                  buckets: <double>[0.2, 0.8, 0.4, 1.0, 0.0],
                  windowStartMs: 0,
                  windowEndMs: 10000,
                  cueBoundariesMs: <int>[1000, 3000, 6000],
                  previewDelayMs: 500,
                  currentPositionMs: 2000,
                  waveColor: const Color(0xFF2196F3),
                  cueLineColor: const Color(0xFFFF9800),
                  playheadColor: const Color(0xFFF44336),
                  centerLineColor: const Color(0xFF9E9E9E),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('empty buckets (degraded) => still renders center/cue/playhead',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 100,
              child: CustomPaint(
                painter: SubtitleWaveformPainter(
                  buckets: const <double>[],
                  windowStartMs: 0,
                  windowEndMs: 10000,
                  cueBoundariesMs: <int>[1000],
                  previewDelayMs: 0,
                  currentPositionMs: 500,
                  waveColor: const Color(0xFF2196F3),
                  cueLineColor: const Color(0xFFFF9800),
                  playheadColor: const Color(0xFFF44336),
                  centerLineColor: const Color(0xFF9E9E9E),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
