import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_borderless_window_fit.dart';

void main() {
  const Rect current = Rect.fromLTWH(120, 80, 1000, 800);

  Rect fit(double aspectRatio) => fitWindowBoundsToAspect(current, aspectRatio);

  test('贴合后窗口宽高比等于视频宽高比（contain 下不留黑边）', () {
    for (final double ratio in <double>[16 / 9, 4 / 3, 21 / 9, 1, 2.35]) {
      final Rect next = fit(ratio);
      // 用相对误差比较：结果经过最小尺寸夹取，可能不是精确相等。
      expect(
        (next.width / next.height - ratio).abs() / ratio,
        lessThan(1e-9),
        reason: 'ratio=$ratio -> ${next.width}x${next.height}',
      );
    }
  });

  test('保持窗口左上角不动', () {
    final Rect next = fit(16 / 9);
    expect(next.left, current.left);
    expect(next.top, current.top);
  });

  test('超宽视频撞到最小高时改为以高反推宽', () {
    // 1000 宽按 4.0 推高只有 250，低于最小高 480 → 应以 480 为基准反推 1920 宽。
    final Rect next = fit(4);
    expect(next.height, 480);
    expect(next.width, closeTo(1920, 1e-9));
    expect(next.height, greaterThanOrEqualTo(kVideoBorderlessMinWindowHeight));
    expect(next.width, greaterThanOrEqualTo(kVideoBorderlessMinWindowWidth));
  });

  test('极端比例下仍不小于窗口最小尺寸', () {
    for (final double ratio in <double>[0.1, 0.4, 6, 20]) {
      final Rect next = fit(ratio);
      expect(
        next.width,
        greaterThanOrEqualTo(kVideoBorderlessMinWindowWidth),
        reason: 'ratio=$ratio width=${next.width}',
      );
      expect(
        next.height,
        greaterThanOrEqualTo(kVideoBorderlessMinWindowHeight),
        reason: 'ratio=$ratio height=${next.height}',
      );
    }
  });

  test('非法宽高比原样返回，不产生 NaN/Infinity', () {
    for (final double ratio in <double>[0, -1, double.nan, double.infinity]) {
      final Rect next = fit(ratio);
      expect(next, current, reason: 'ratio=$ratio');
      expect(next.width.isFinite, isTrue);
      expect(next.height.isFinite, isTrue);
    }
  });
}
