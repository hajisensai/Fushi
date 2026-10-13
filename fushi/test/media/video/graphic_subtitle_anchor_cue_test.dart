import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3319：图形字幕（PGS，libmpv 自绘）制卡只有一张黑图、没有同步视频和句子音频。
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

  group('图形字幕逐句时间表（任何制卡入口都有句子时间）', () {
    AudioCue timing(int start, int end) => AudioCue()
      ..bookKey = ''
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = ''
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0;

    test('PGS 位图时间表 → 逐句无文字 cue，首尾相接的两句不合并', () {
      final List<AudioCue> cues = graphicSubtitleTimingCuesFromRegions(
        GraphicSubtitleRegionTrack(
          canvas: const Size(1920, 1080),
          regions: const <GraphicSubtitleRegion>[
            GraphicSubtitleRegion(
              startMs: 5000,
              endMs: 7000,
              rect: Rect.fromLTRB(0, 0, 10, 10),
            ),
            GraphicSubtitleRegion(
              startMs: 1000,
              endMs: 3000,
              rect: Rect.fromLTRB(0, 0, 10, 10),
            ),
            GraphicSubtitleRegion(
              startMs: 3000,
              endMs: 4500,
              rect: Rect.fromLTRB(0, 0, 10, 10),
            ),
          ],
        ),
      );
      expect(
        cues.map((AudioCue c) => (c.sentenceIndex, c.startMs, c.endMs, c.text)),
        <(int, int, int, String)>[
          (0, 1000, 3000, ''),
          (1, 3000, 4500, ''),
          (2, 5000, 7000, ''),
        ],
      );
    });

    test('图形模式 + 有时间表：制卡流 / 调轴 / 所属流都认它（排在副字幕前）', () {
      final VideoPlayerController c = VideoPlayerController()
        ..setSecondaryCues(<AudioCue>[_text(0, 0, 99999)])
        ..debugSetGraphicSubtitleActiveForTesting(true);
      final List<AudioCue> timings = <AudioCue>[
        timing(1000, 3000),
        timing(5000, 7000),
      ];
      c.debugSetGraphicTimingCuesForTesting(timings);
      c.setDelayMs(300);
      c.setSecondaryDelayMs(-2000);
      expect(c.miningCues.map((AudioCue x) => x.startMs), <int>[1000, 5000]);
      expect(c.miningDelayMs, 300);
      expect(c.delayMsForCue(c.miningCues[1]), 300);
      expect(
        c.cueStreamOwning(c.miningCues[0]).map((AudioCue x) => x.startMs),
        <int>[1000, 5000],
      );
      // 退出图形模式后时间表不再生效（回落副字幕流）。
      c.debugSetGraphicSubtitleActiveForTesting(false);
      expect(c.miningCues.single.text, 'cue0');
    });

    test('锚点：mpv 缺 sub-end 时用时间表的真实结束，不用 5 秒暂定', () {
      final VideoPlayerController c = VideoPlayerController()
        ..debugSetGraphicSubtitleActiveForTesting(true);
      c.debugSetGraphicTimingCuesForTesting(<AudioCue>[
        timing(1000, 3000),
        timing(12000, 13500),
      ]);
      final AudioCue? cue = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: 'あいう',
        rawStart: '12.040000',
        rawEnd: '',
      );
      expect((cue!.startMs, cue.endMs, cue.text), (12000, 13500, 'あいう'));
      // 锚点归属时间表：padding 按真实邻句夹边。
      expect(c.cueStreamOwning(cue).length, 2);
    });

    test('锚点：画面上恰好没字（mpv 无 sub-start）时按播放位置锚到最近那句', () {
      final VideoPlayerController c = VideoPlayerController()
        ..debugSetGraphicSubtitleActiveForTesting(true);
      c.debugSetGraphicTimingCuesForTesting(<AudioCue>[
        timing(1000, 3000),
        timing(5000, 7000),
      ]);
      c.debugSetPositionForTesting(4200);
      final AudioCue? cue = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: 'えお',
        rawStart: '',
        rawEnd: '',
      );
      expect((cue!.startMs, cue.endMs), (1000, 3000));
      c.debugSetPositionForTesting(6000);
      final AudioCue? inside = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: 'えお',
        rawStart: '',
        rawEnd: '',
      );
      expect((inside!.startMs, inside.endMs), (5000, 7000));
    });

    test('选轨后后台加载时间表；换轨（世代变化）后迟到的结果丢弃', () async {
      final _FakeRegionLoader loader = _FakeRegionLoader();
      final VideoPlayerController c = VideoPlayerController()
        ..debugSetGraphicSubtitleActiveForTesting(
          true,
          streamIndex: 0,
          codec: 'hdmv_pgs_subtitle',
        )
        ..graphicSubtitleRegionLoader = loader;
      c.debugSetVideoPathForTesting(r'C:\v\ep01.mkv');
      c.debugLoadGraphicSubtitleTimingsForTesting(
        streamIndex: 0,
        codec: 'hdmv_pgs_subtitle',
      );
      loader.complete(<GraphicSubtitleRegion>[
        const GraphicSubtitleRegion(
          startMs: 1000,
          endMs: 2000,
          rect: Rect.fromLTRB(0, 0, 1, 1),
        ),
      ]);
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.single.startMs, 1000);

      c.debugLoadGraphicSubtitleTimingsForTesting(
        streamIndex: 0,
        codec: 'hdmv_pgs_subtitle',
      );
      // 第二次加载还没回来时又换了一次（世代 +1）：第二次的结果作废。
      c.debugLoadGraphicSubtitleTimingsForTesting(
        streamIndex: 0,
        codec: 'hdmv_pgs_subtitle',
      );
      loader.complete(<GraphicSubtitleRegion>[
        const GraphicSubtitleRegion(
          startMs: 9000,
          endMs: 9500,
          rect: Rect.fromLTRB(0, 0, 1, 1),
        ),
      ]);
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.single.startMs, 1000);
    });
  });
}

/// 时间表来源替身：每次 load 排队，[complete] 按先后交结果。
class _FakeRegionLoader implements GraphicSubtitleRegionLoader {
  final List<Completer<GraphicSubtitleRegionTrack?>> _pending =
      <Completer<GraphicSubtitleRegionTrack?>>[];

  @override
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  }) {
    final Completer<GraphicSubtitleRegionTrack?> c =
        Completer<GraphicSubtitleRegionTrack?>();
    _pending.add(c);
    return c.future;
  }

  void complete(List<GraphicSubtitleRegion> regions) {
    _pending
        .removeAt(0)
        .complete(
          GraphicSubtitleRegionTrack(
            canvas: const Size(1920, 1080),
            regions: regions,
          ),
        );
  }
}
