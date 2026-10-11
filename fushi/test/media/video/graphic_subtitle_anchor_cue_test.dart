import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3274：图形字幕（PGS，libmpv 自绘）制卡只有一张黑图、没有同步视频和句子音频。
///
/// 根因：图形轨没有 Dart 侧 cue，暂停 OCR 层查词不带锚点 → 制卡区间 `0..0`。修复从
/// mpv `sub-start` / `sub-end` 建在屏那句的锚点 cue；这里钉住「锚点怎么建」与「控制器
/// 按什么流 / 什么调轴解释它」——宿主无 libmpv，经测试钩子喂 mpv 原始属性串，走与
/// 真实读取同一条落地函数。
AudioCue _text(int index, int start, int end) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = index
  ..textFragmentId = ''
  ..text = 'cue$index'
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0;

void main() {
  group('buildGraphicSubtitleAnchorCue', () {
    test('mpv 起止 → 字幕时基窗，文本用 OCR 句', () {
      final AudioCue? cue = buildGraphicSubtitleAnchorCue(
        text: ' 走り出した。\r\n',
        startMs: parseMpvSecondsToMs('753.420000'),
        endMs: parseMpvSecondsToMs('755.880000'),
      );
      expect(cue, isNotNull);
      expect(cue!.startMs, 753420);
      expect(cue.endMs, 755880);
      expect(cue.text, '走り出した。');
    });

    test('画面上没有字幕（mpv 无 sub-start）→ null，不按位置编假窗', () {
      expect(
        buildGraphicSubtitleAnchorCue(
          text: '走り出した。',
          startMs: parseMpvSecondsToMs(''),
          endMs: parseMpvSecondsToMs(''),
        ),
        isNull,
      );
    });

    test('缺 sub-end（PGS 结束段未到）→ 暂定时长，区间仍为正', () {
      final AudioCue? cue = buildGraphicSubtitleAnchorCue(
        text: '走り出した。',
        startMs: 10000,
        endMs: null,
      );
      expect(cue!.startMs, 10000);
      expect(cue.endMs, 10000 + kPlayerDecodedCueProvisionalMs);
    });

    test('OCR 文本为空 → null', () {
      expect(
        buildGraphicSubtitleAnchorCue(text: '  ', startMs: 1000, endMs: 2000),
        isNull,
      );
    });
  });

  group('VideoPlayerController 图形字幕锚点', () {
    test('非图形模式不产锚点（文本字幕 / 已整轨转文字走自己的 cue）', () async {
      final VideoPlayerController c = VideoPlayerController();
      expect(
        c.debugAdoptGraphicSubtitleAnchorForTesting(
          text: '走り出した。',
          rawStart: '1.000000',
          rawEnd: '2.000000',
        ),
        isNull,
      );
      // 真实读取入口在非图形模式 / 未 load 时同样直接 null。
      expect(await c.currentGraphicSubtitleCue(text: '走り出した。'), isNull);
    });

    test('锚点走主轨调轴（= libmpv sub-delay），不被副字幕独立调轴带偏', () {
      final VideoPlayerController c = VideoPlayerController();
      c.debugSetGraphicSubtitleActiveForTesting(
        true,
        streamIndex: 0,
        codec: 'hdmv_pgs_subtitle',
      );
      // 图形模式下主流 cues 为空；开着一条副字幕且单独调轴。
      c.setSecondaryCues(<AudioCue>[_text(0, 750000, 752000)]);
      c.setSecondaryDelayMs(-3000);
      c.debugSetDelayMsForTesting(1200, positionMs: 0);
      expect(c.debugSubtitleDelayMpvMs, 1200);
      expect(c.miningDelayMs, -3000, reason: '兜底口径会错拿副轨调轴');

      final AudioCue anchor = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: '走り出した。',
        rawStart: '753.420000',
        rawEnd: '755.880000',
      )!;
      expect(c.delayMsForCue(anchor), 1200);
      // 制卡逆变换：字幕时基 + sub-delay = 用户实际看到 / 听到的播放器轴。
      expect(miningClipTimeMs(anchor.startMs, c.delayMsForCue(anchor)), 754620);
      expect(miningClipTimeMs(anchor.endMs, c.delayMsForCue(anchor)), 757080);
    });

    test('锚点自成单句流：padding 不按副字幕邻句夹边、上下文不取副字幕句', () {
      final VideoPlayerController c = VideoPlayerController();
      c.debugSetGraphicSubtitleActiveForTesting(true, streamIndex: 0);
      c.setSecondaryCues(<AudioCue>[
        _text(0, 750000, 753500),
        _text(1, 755000, 758000),
      ]);
      final AudioCue anchor = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: '走り出した。',
        rawStart: '753.420000',
        rawEnd: '755.880000',
      )!;
      expect(c.cueStreamOwning(anchor), <AudioCue>[anchor]);
      // 非锚点的游离 cue 维持既有兜底（有效流）。
      final AudioCue stray = _text(9, 1, 2);
      expect(c.cueStreamOwning(stray), same(c.miningCues));
    });
  });
}
