import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_delay_slider_range.dart';

void main() {
  group('subtitleDelaySliderRangeMs（反馈 pHsnXu5YSg：滑条范围不够）', () {
    test('小偏移保持基础 ±30 s，比旧的 ±10 s 宽', () {
      expect(subtitleDelaySliderRangeMs(0), 30000);
      expect(subtitleDelaySliderRangeMs(12000), 30000);
      expect(subtitleDelaySliderRangeMs(-29999), 30000);
    });

    test('拖到端点松手后扩一档，可以继续往外拖', () {
      expect(subtitleDelaySliderRangeMs(30000), 60000);
      expect(subtitleDelaySliderRangeMs(-30000), 60000);
      expect(subtitleDelaySliderRangeMs(60000), 90000);
    });

    test('封顶与播放器 clamp 一致', () {
      expect(
        subtitleDelaySliderRangeMs(kSubtitleDelayClampMs),
        kSubtitleDelayClampMs,
      );
      expect(subtitleDelaySliderRangeMs(-590000), kSubtitleDelayClampMs);
    });

    test('分档：基础范围 50 ms 一档，扩展后 100 ms 一档', () {
      expect(subtitleDelaySliderDivisions(30000), 1200);
      expect(subtitleDelaySliderDivisions(60000), 1200);
      expect(subtitleDelaySliderDivisions(kSubtitleDelayClampMs), 12000);
    });
  });
}
