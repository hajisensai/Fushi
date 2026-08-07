import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/series_playback_prefs.dart';

// 同系列（合集）播放偏好解析（schema v52）单测：锁住「系列级优先、回退 per-book」的
// 优先级语义，尤其是 delayMs 用 nullable 区分「系列没设过（null）」与「显式调成 0」。
void main() {
  group('effectiveSeriesAudioTrackId — 同系列音轨记忆', () {
    test('系列级非 null 时优先于 per-book（合集内共享）', () {
      expect(effectiveSeriesAudioTrackId('jpn', 'eng'), 'jpn');
    });

    test('系列级为 null 时回退 per-book（兼容迁移前各集已存值）', () {
      expect(effectiveSeriesAudioTrackId(null, 'eng'), 'eng');
    });

    test('两者皆 null → null（跟随 libmpv 默认）', () {
      expect(effectiveSeriesAudioTrackId(null, null), isNull);
    });

    test('系列级空串是显式值，不回退（?? 只对 null 生效）', () {
      expect(effectiveSeriesAudioTrackId('', 'eng'), '');
    });
  });

  group('effectiveSeriesDelayMs — 同系列字幕调轴记忆', () {
    test('系列级非 null 时优先于 per-book', () {
      expect(effectiveSeriesDelayMs(1500, 0), 1500);
    });

    test('系列级显式 0 优先（区别于「系列没设过」的 null）', () {
      // 关键设计点：nullable delayMs 才能区分「显式调成 0」与「没设过」。
      expect(effectiveSeriesDelayMs(0, 800), 0);
    });

    test('系列级为 null 时回退 per-book', () {
      expect(effectiveSeriesDelayMs(null, 800), 800);
    });

    test('系列级 null + per-book 0（列默认）→ 0', () {
      expect(effectiveSeriesDelayMs(null, 0), 0);
    });

    test('负值（画面先于文字）正确透传', () {
      expect(effectiveSeriesDelayMs(-1200, 0), -1200);
    });
  });
}
