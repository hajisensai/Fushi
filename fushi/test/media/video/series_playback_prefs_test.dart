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

  // TODO-2837（schema v86）：副字幕独立调轴的两层决议。与主轨同一优先级语义，
  // 仅回退终点不同：两层皆 null → null = 跟随主字幕（v86 前行为）。
  group('effectiveSeriesSecondaryDelayMs — 同系列副字幕调轴记忆', () {
    test('系列级非 null 时优先于 per-book', () {
      expect(effectiveSeriesSecondaryDelayMs(1500, 300), 1500);
    });

    test('系列级显式 0 优先（区别于「系列没设过」的 null）', () {
      expect(effectiveSeriesSecondaryDelayMs(0, 800), 0);
    });

    test('系列级为 null 时回退 per-book', () {
      expect(effectiveSeriesSecondaryDelayMs(null, 800), 800);
    });

    test('per-book 显式 0 是独立值，不塌成跟随', () {
      expect(effectiveSeriesSecondaryDelayMs(null, 0), 0);
    });

    test('两层皆 null → null = 副字幕跟随主字幕调轴（升级后行为不变的关键）', () {
      expect(effectiveSeriesSecondaryDelayMs(null, null), isNull);
    });

    test('负值正确透传', () {
      expect(effectiveSeriesSecondaryDelayMs(-1200, null), -1200);
    });
  });
}
