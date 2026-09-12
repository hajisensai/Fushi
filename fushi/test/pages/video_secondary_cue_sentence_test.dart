import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

AudioCue _cue(int startMs, int endMs, String text) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// 副字幕例句（`{secondary-cue-sentence}`）在视频页的取值：副轨在制卡播放器窗内的
/// 全部 cue，按副轨自己的生效调轴换算坐标。纯函数 [secondaryCueSentenceForClip] 单测 +
/// 接线守卫（`_resolveVideoMiningRange` 真把它算出来并送进引擎请求）。
void main() {
  final List<AudioCue> secondary = <AudioCue>[
    _cue(0, 1000, '第一句'),
    _cue(1000, 2000, '第二句'),
    _cue(2000, 3000, '第三句'),
    _cue(5000, 6000, '第五句'),
  ];

  group('secondaryCueSentenceForClip', () {
    test('取与播放器窗重叠的副 cue（半开区间，边界相接不算重叠）', () {
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: secondary,
          clipStartMs: 1200,
          clipEndMs: 1800,
          secondaryDelayMs: 0,
        ),
        '第二句',
      );
      // 窗 [1000, 2000)：第一句 end==1000 不算、第三句 start==2000 不算。
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: secondary,
          clipStartMs: 1000,
          clipEndMs: 2000,
          secondaryDelayMs: 0,
        ),
        '第二句',
      );
    });

    test('宽窗（多句合一草稿）覆盖多条副 cue → 按时间顺序换行拼接', () {
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: secondary,
          clipStartMs: 500,
          clipEndMs: 2500,
          secondaryDelayMs: 0,
        ),
        '第一句\n第二句\n第三句',
      );
    });

    test('副轨独立调轴：播放器窗按副轨 delay 换算回副轨坐标再匹配', () {
      // 副轨 delay +1000：字幕坐标 t 在播放器轴 t+1000 显示。播放器窗 [2200, 2800)
      // → 副轨坐标 [1200, 1800) → 第二句（而不是按播放器轴硬碰到的第三句）。
      final String? got = secondaryCueSentenceForClip(
        secondaryCues: secondary,
        clipStartMs: 2200,
        clipEndMs: 2800,
        secondaryDelayMs: 1000,
      );
      expect(got, '第二句');
      // 与 effectiveSubtitlePositionMs 同一方向（减 delay），不是反向。
      expect(effectiveSubtitlePositionMs(2200, 1000), 1200);
    });

    test('空窗 / 无副字幕 / 窗内无副 cue → null（不退回主轨文本）', () {
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: secondary,
          clipStartMs: 0,
          clipEndMs: 0,
          secondaryDelayMs: 0,
        ),
        isNull,
        reason: '取不到锚定 cue 时视频页兜底成 0/0 空窗',
      );
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: const <AudioCue>[],
          clipStartMs: 0,
          clipEndMs: 1000,
          secondaryDelayMs: 0,
        ),
        isNull,
      );
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: secondary,
          clipStartMs: 3500,
          clipEndMs: 4500,
          secondaryDelayMs: 0,
        ),
        isNull,
      );
    });

    test('副 cue 文本全空白 → null（不产出空串字段值）', () {
      expect(
        secondaryCueSentenceForClip(
          secondaryCues: <AudioCue>[_cue(0, 1000, '  ')],
          clipStartMs: 0,
          clipEndMs: 1000,
          secondaryDelayMs: 0,
        ),
        isNull,
      );
    });
  });

  group('视频页接线守卫', () {
    late String src;
    setUpAll(() => src = maskComments(readVideoFushiSource()));

    test('_resolveVideoMiningRange 用副轨生效调轴算副字幕例句', () {
      final int start = src.indexOf('_resolveVideoMiningRange(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('_onMineEntryImpl', start);
      final String body = src.substring(start, end);
      expect(body, contains('secondaryCueSentenceForClip('));
      expect(body, contains('secondaryCues: controller.secondaryCues'));
      expect(
        body,
        contains('secondaryDelayMs: controller.effectiveSecondaryDelayMs'),
        reason: '副轨独立调轴后必须用副轨生效轴换算，不能借主轨 delay',
      );
    });

    test('_mineVideoCard 把副字幕例句送进 ImmersionMiningRequest', () {
      final int start = src.indexOf('ImmersionMiningRequest(');
      expect(start, greaterThanOrEqualTo(0));
      final String body = src.substring(start, start + 2000);
      expect(body, contains('secondaryCueSentence: secondaryCueSentence'));
    });
  });
}
