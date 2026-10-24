import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_jump_history.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';

void main() {
  group('isVideoPositionJump', () {
    test('跨度达到阈值才算跳转（两个方向）', () {
      expect(isVideoPositionJump(fromMs: 60000, toMs: 75000), isTrue);
      expect(isVideoPositionJump(fromMs: 75000, toMs: 60000), isTrue);
      expect(isVideoPositionJump(fromMs: 60000, toMs: 74999), isFalse);
    });

    test('±10 秒步进与逐句不算', () {
      expect(isVideoPositionJump(fromMs: 60000, toMs: 70000), isFalse);
      expect(isVideoPositionJump(fromMs: 60000, toMs: 57000), isFalse);
    });

    test('出发点未知不算', () {
      expect(isVideoPositionJump(fromMs: null, toMs: 600000), isFalse);
    });
  });

  test('同一处判据：1 秒内视为同一位置', () {
    final JumpHistory<int> history = createVideoJumpHistory();
    expect(history.recordDeparture(60000), isTrue);
    expect(history.recordDeparture(60900), isFalse);
    expect(history.recordDeparture(61000), isTrue);
  });

  group('VideoSeekBarJumpTracker', () {
    test('进度条按下后的大跨度落点返回出发点，且只消费一次', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 3);
      expect(tracker.commit(600000, relativeBaseCaptureCount: 3), 60000);
      expect(tracker.originMs, isNull);
      expect(tracker.commit(900000, relativeBaseCaptureCount: 3), isNull);
    });

    test('没按过进度条的落点（横滑 / 双击）不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      expect(tracker.commit(600000, relativeBaseCaptureCount: 0), isNull);
    });

    test('按下后中间插进了相对步进（取过相对基准）不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 3);
      expect(tracker.commit(600000, relativeBaseCaptureCount: 4), isNull);
    });

    test('进度条上的小幅拖动不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 0);
      expect(tracker.commit(65000, relativeBaseCaptureCount: 0), isNull);
    });

    test('cancel 作废出发点', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 0);
      tracker.cancel();
      expect(tracker.commit(600000, relativeBaseCaptureCount: 0), isNull);
    });
  });
}
