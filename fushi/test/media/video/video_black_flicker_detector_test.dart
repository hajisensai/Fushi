import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_black_flicker_detector.dart';

/// 便捷构造：给定「本窗新增迟帧数」返回一个 1 秒播放采样，内部把累计值自增维护。
class _Feeder {
  _Feeder(this.detector);
  final VideoBlackFlickerDetector detector;
  int _cumulative = 0;

  /// 喂一个 1000ms 播放窗，本窗新增 [deltaLateFrames] 迟帧，返回是否刚触发。
  bool play(int deltaLateFrames) {
    _cumulative += deltaLateFrames;
    return detector.addSample(VideoFlickerSample(
      cumulativeLateFrames: _cumulative,
      windowMs: 1000,
      playing: true,
    ));
  }

  /// 喂一个暂停窗（累计不变），返回是否触发（应恒 false）。
  bool pause() {
    return detector.addSample(VideoFlickerSample(
      cumulativeLateFrames: _cumulative,
      windowMs: 1000,
      playing: false,
    ));
  }
}

void main() {
  group('VideoBlackFlickerDetector', () {
    test('持续高迟帧率达到连续窗阈值时触发一次', () {
      final VideoBlackFlickerDetector d = VideoBlackFlickerDetector(
        lateFramesPerSecondThreshold: 8,
        sustainedBadWindows: 3,
      );
      final _Feeder f = _Feeder(d);
      // 第一个样本只重定基线（无增量判定）。
      expect(f.play(0), isFalse);
      // 连续 3 个坏窗（每窗 10 迟帧 >= 8/s）：第 3 个触发。
      expect(f.play(10), isFalse); // 坏窗 1
      expect(f.play(10), isFalse); // 坏窗 2
      expect(f.play(10), isTrue); // 坏窗 3 -> 触发
      expect(d.hasFired, isTrue);
    });

    test('触发后永不再触发（每生命周期一次）', () {
      final VideoBlackFlickerDetector d =
          VideoBlackFlickerDetector(sustainedBadWindows: 2);
      final _Feeder f = _Feeder(d);
      f.play(0);
      f.play(20);
      expect(f.play(20), isTrue); // 触发
      // 继续坏窗：不再返回 true。
      expect(f.play(50), isFalse);
      expect(f.play(50), isFalse);
    });

    test('低于阈值的迟帧不触发', () {
      final VideoBlackFlickerDetector d = VideoBlackFlickerDetector(
        lateFramesPerSecondThreshold: 8,
        sustainedBadWindows: 3,
      );
      final _Feeder f = _Feeder(d);
      f.play(0);
      for (int i = 0; i < 20; i++) {
        // 每窗 5 迟帧 < 8/s：永远是好窗。
        expect(f.play(5), isFalse);
      }
      expect(d.hasFired, isFalse);
    });

    test('短暂尖峰（少于连续窗阈值）不触发', () {
      final VideoBlackFlickerDetector d = VideoBlackFlickerDetector(
        lateFramesPerSecondThreshold: 8,
        sustainedBadWindows: 3,
      );
      final _Feeder f = _Feeder(d);
      f.play(0);
      expect(f.play(30), isFalse); // 坏窗 1
      expect(f.play(30), isFalse); // 坏窗 2
      expect(f.play(1), isFalse); // 好窗打断连击
      expect(f.play(30), isFalse); // 坏窗 1（重新计）
      expect(f.play(30), isFalse); // 坏窗 2
      expect(d.hasFired, isFalse);
    });

    test('暂停重置连击并重定基线（不把暂停跨度误算成迟帧）', () {
      final VideoBlackFlickerDetector d = VideoBlackFlickerDetector(
        lateFramesPerSecondThreshold: 8,
        sustainedBadWindows: 3,
      );
      final _Feeder f = _Feeder(d);
      f.play(0);
      f.play(30); // 坏窗 1
      f.play(30); // 坏窗 2
      expect(d.consecutiveBadWindows, 2);
      // 暂停：清零连击、重定基线。
      expect(f.pause(), isFalse);
      expect(d.consecutiveBadWindows, 0);
      // 恢复：第一个播放窗只重定基线（不因暂停期计数差触发）。
      expect(f.play(0), isFalse);
      // 需要重新累积连续坏窗。
      expect(f.play(30), isFalse); // 坏窗 1
      expect(f.play(30), isFalse); // 坏窗 2
      expect(f.play(30), isTrue); // 坏窗 3 -> 触发
    });

    test('累计计数器回退（换片重置）时按 0 增量处理，不误报', () {
      final VideoBlackFlickerDetector d =
          VideoBlackFlickerDetector(sustainedBadWindows: 2);
      // 基线很高。
      expect(
        d.addSample(const VideoFlickerSample(
          cumulativeLateFrames: 1000,
          windowMs: 1000,
          playing: true,
        )),
        isFalse,
      );
      // libmpv 换片把计数器重置回小值：负增量按 0，好窗、清连击。
      expect(
        d.addSample(const VideoFlickerSample(
          cumulativeLateFrames: 5,
          windowMs: 1000,
          playing: true,
        )),
        isFalse,
      );
      expect(d.consecutiveBadWindows, 0);
    });

    test('windowMs 非法（<=0）只重定基线不判定', () {
      final VideoBlackFlickerDetector d =
          VideoBlackFlickerDetector(sustainedBadWindows: 1);
      expect(
        d.addSample(const VideoFlickerSample(
          cumulativeLateFrames: 0,
          windowMs: 0,
          playing: true,
        )),
        isFalse,
      );
      expect(
        d.addSample(const VideoFlickerSample(
          cumulativeLateFrames: 100,
          windowMs: 0,
          playing: true,
        )),
        isFalse,
      );
      expect(d.hasFired, isFalse);
    });
  });
}
