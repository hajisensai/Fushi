import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-104b / BUG-188：视频制卡缺真实句子音频。
///
/// 用户原话「有声书和视频制卡没句子声音」——视频制卡应附**当前正在学那句字幕**对应的
/// 视频声轨真实音频段（绝无 TTS）。根因：制卡取 cue 复用 [VideoPlayerController.currentCue]，
/// 而它被字幕显示语义独占——句间静音 gap / 末句之后被清成 null（BUG-074，字幕条该消失）。
/// 用户常在「字幕刚消失那一瞬」（已暂停、字幕条已撤但查词浮层还在）制卡 → currentCue==null
/// → 制卡链路 `_lastLookupCue ?? currentCue` 拿不到 cue → 句子音频字段空。
///
/// 修复：制卡走独立的 [resolveMiningCueForPosition]，按播放位置解析「用户最后看到的那句」，
/// 不复用被 gap 清空的 UI 状态。本组测试直接覆盖这个纯函数：
/// - 撤掉 floor 兜底（gap 时退回裸 findCueIndex）会让「gap / 末句后」用例转红 = 守卫成立。
/// - 正常显示期（位置落在 cue 时间窗内）仍精确命中，不回归字幕显示路径。
AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  group('resolveMiningCueForPosition (TODO-104b / BUG-188)', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 0, 1000),
      _cue(1, 2000, 3000),
      _cue(2, 5000, 6000),
    ];

    test('显示期（位置落在 cue 时间窗内）精确命中当前句，不回归字幕路径', () {
      // 位置落在 cue1 [2000,3000] 内 → 命中 cue1。
      final AudioCue? cue =
          resolveMiningCueForPosition(cues: cues, positionMs: 2500, delayMs: 0);
      expect(cue, isNotNull);
      expect(cue!.text, 'line1');
    });

    test('cue 起点 / 终点闭区间边界命中当前句', () {
      expect(
        resolveMiningCueForPosition(cues: cues, positionMs: 2000, delayMs: 0)
            ?.text,
        'line1',
      );
      expect(
        resolveMiningCueForPosition(cues: cues, positionMs: 3000, delayMs: 0)
            ?.text,
        'line1',
      );
    });

    test('根因复现：句间 gap（currentCue 此刻为 null）仍解析到刚播完那句', () {
      // 1500 落在 cue0(0..1000) 与 cue1(2000..3000) 之间的静音 gap：
      // 字幕显示路径（findCueIndex）返回 -1，但制卡应取「最后看到的」cue0。
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 1500),
        -1,
        reason: 'gap 时字幕显示路径确实清空（BUG-074），故需独立解析',
      );
      final AudioCue? cue =
          resolveMiningCueForPosition(cues: cues, positionMs: 1500, delayMs: 0);
      expect(cue, isNotNull, reason: '撤掉 floor 兜底此处转红 = 守卫成立');
      expect(cue!.text, 'line0');
    });

    test('末句之后（currentCue 已清空）解析到最后一条 cue', () {
      // 6500 在末句 cue2(5000..6000) 之后：findCueIndex=-1，制卡取 cue2。
      expect(
          JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 6500), -1);
      final AudioCue? cue =
          resolveMiningCueForPosition(cues: cues, positionMs: 6500, delayMs: 0);
      expect(cue?.text, 'line2');
    });

    test('多段 gap 各自回退到前一条已播 cue', () {
      // cue1 与 cue2 之间的 gap(3000..5000)：3500 → 回退 cue1。
      expect(
        resolveMiningCueForPosition(cues: cues, positionMs: 3500, delayMs: 0)
            ?.text,
        'line1',
      );
    });

    test('位置早于全部 cue（一句都没起播过）诚实返回 null', () {
      final List<AudioCue> later = <AudioCue>[_cue(0, 1000, 2000)];
      expect(
        resolveMiningCueForPosition(cues: later, positionMs: 500, delayMs: 0),
        isNull,
      );
    });

    test('空 cue 列表诚实返回 null（无字幕视频）', () {
      expect(
        resolveMiningCueForPosition(
          cues: const <AudioCue>[],
          positionMs: 1234,
          delayMs: 0,
        ),
        isNull,
      );
    });

    test('音画延迟扣减后再解析（与字幕显示同一 effective 坐标系）', () {
      // delayMs=600：位置 2400 - 600 = 1800 落在 cue0..cue1 的 gap → 回退 cue0。
      expect(
        resolveMiningCueForPosition(cues: cues, positionMs: 2400, delayMs: 600)
            ?.text,
        'line0',
      );
      // 同位置无延迟时 2400 落在 cue1 时间窗内 → 命中 cue1，证明 delay 真的参与解析。
      expect(
        resolveMiningCueForPosition(cues: cues, positionMs: 2400, delayMs: 0)
            ?.text,
        'line1',
      );
    });
  });

  group('resolveMiningCueIndexForPosition (下标版，单句解析底层)', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 0, 1000),
      _cue(1, 2000, 3000),
      _cue(2, 5000, 6000),
    ];

    test('显示期命中返回该 cue 下标', () {
      expect(
        resolveMiningCueIndexForPosition(
            cues: cues, positionMs: 2500, delayMs: 0),
        1,
      );
    });

    test('gap / 末句后 floor 回退到最近一条已播 cue 的下标', () {
      // 1500 在 cue0..cue1 gap → floor 回退 cue0（下标 0）。
      expect(
        resolveMiningCueIndexForPosition(
            cues: cues, positionMs: 1500, delayMs: 0),
        0,
      );
      // 6500 在末句之后 → floor 回退 cue2（下标 2）。
      expect(
        resolveMiningCueIndexForPosition(
            cues: cues, positionMs: 6500, delayMs: 0),
        2,
      );
    });

    test('位置早于全部 cue / 空列表返回 -1（一句都没起播）', () {
      expect(
        resolveMiningCueIndexForPosition(
            cues: <AudioCue>[_cue(0, 1000, 2000)], positionMs: 500, delayMs: 0),
        -1,
      );
      expect(
        resolveMiningCueIndexForPosition(
            cues: const <AudioCue>[], positionMs: 1234, delayMs: 0),
        -1,
      );
    });

    test('单句版与下标版同源（idx>=0 时返回同一 cue）', () {
      final int idx = resolveMiningCueIndexForPosition(
          cues: cues, positionMs: 2500, delayMs: 0);
      final AudioCue? cue =
          resolveMiningCueForPosition(cues: cues, positionMs: 2500, delayMs: 0);
      expect(idx, greaterThanOrEqualTo(0));
      expect(identical(cue, cues[idx]), isTrue);
    });
  });

  group('miningClipTimeMs (TODO-680 / BUG-392：字幕调轴应用到制卡裁剪时间)', () {
    test('delay=0 时不动（裁的就是字幕原始时间窗）', () {
      expect(miningClipTimeMs(10000, 0), 10000);
      expect(miningClipTimeMs(12000, 0), 12000);
    });

    test('正 delay：字幕坐标 + delay = 播放器轴（用户实际听到的更晚位置）', () {
      // 字幕整体延后 600ms 才对上画面：字幕文件 [10000,12000] 对应播放轴 [10600,12600]。
      // 撤掉 `+ delayMs` 会让此处转红 = 守卫成立（裁早了 600ms，串上一句尾巴）。
      expect(miningClipTimeMs(10000, 600), 10600);
      expect(miningClipTimeMs(12000, 600), 12600);
    });

    test('负 delay：字幕提前，裁剪点相应前移', () {
      expect(miningClipTimeMs(10000, -600), 9400);
    });

    test('下界 clamp 到 0（负 delay 把早期 cue 压到负数时不为负）', () {
      expect(miningClipTimeMs(100, -600), 0);
    });

    test('与 effectiveSubtitlePositionMs 互为逆变换（往返还原）', () {
      // effective = playerPos - delay（选句用）；miningClip = subtitleTime + delay（裁剪用）。
      // 二者方向相反：把一个播放位置换成字幕坐标再换回去，得回原播放位置（避开 clamp 区）。
      const int playerPos = 12345;
      for (final int delay in <int>[0, 600, -600, 2500]) {
        final int subtitle = effectiveSubtitlePositionMs(playerPos, delay);
        expect(miningClipTimeMs(subtitle, delay), playerPos,
            reason: 'delay=$delay 往返应还原');
      }
    });
  });
}
