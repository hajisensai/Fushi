// 视频车道「高级制卡」覆盖项 → 这张卡的区间 / 图片方式（纯函数，写卡与对话框试听同源）。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/advanced_mining/video_advanced_mining.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show MiningMosaicRegion, MiningRequestOverrides;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

const VideoMiningRange _range = (
  clipStartMs: 10880,
  clipEndMs: 14620,
  stillFrameAtMs: 11000,
  sentence: 'それでも',
  cueSentence: 'それでも',
);

void main() {
  group('applyVideoMiningOverrides', () {
    test('没有覆盖项原样返回', () {
      expect(applyVideoMiningOverrides(_range, null), _range);
    });

    test('起止偏移加在最终窗口上（已含留白的区间），不夹相邻句', () {
      final VideoMiningRange r = applyVideoMiningOverrides(
        _range,
        const MiningRequestOverrides(
          audioStartDeltaMs: -250,
          audioEndDeltaMs: 500,
        ),
      );
      expect(r.clipStartMs, 10630);
      expect(r.clipEndMs, 15120);
      expect(r.stillFrameAtMs, 11000, reason: '音频偏移不挪封面帧');
      expect(r.sentence, 'それでも');
    });

    test('起点不早于 0，终点至少比起点晚 100ms', () {
      final VideoMiningRange r = applyVideoMiningOverrides(
        _range,
        const MiningRequestOverrides(
          audioStartDeltaMs: -20000,
          audioEndDeltaMs: -20000,
        ),
      );
      expect(r.clipStartMs, 0);
      expect(r.clipEndMs, 100);
    });

    test('无区间（0..0 哨兵）不被偏移变出一段区间', () {
      const VideoMiningRange none = (
        clipStartMs: 0,
        clipEndMs: 0,
        stillFrameAtMs: 5000,
        sentence: '',
        cueSentence: null,
      );
      final VideoMiningRange r = applyVideoMiningOverrides(
        none,
        const MiningRequestOverrides(audioEndDeltaMs: 500),
      );
      expect(r.clipStartMs, 0);
      expect(r.clipEndMs, 0);
    });

    test('coverFrameAtMs 替换静帧时刻', () {
      final VideoMiningRange r = applyVideoMiningOverrides(
        _range,
        const MiningRequestOverrides(coverFrameAtMs: 11042),
      );
      expect(r.stillFrameAtMs, 11042);
      expect(r.clipStartMs, _range.clipStartMs);
      expect(r.clipEndMs, _range.clipEndMs);
    });
  });

  group('resolveVideoMiningImageMode', () {
    test('覆盖项替换设置值', () {
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.videoClip,
          overrides: const MiningRequestOverrides(videoImageMode: 'gif'),
        ),
        VideoMiningImageMode.gif,
      );
    });

    test('认不出的 wire 值不当成片段：退回设置', () {
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.gif,
          overrides: const MiningRequestOverrides(videoImageMode: 'nonsense'),
        ),
        VideoMiningImageMode.gif,
      );
    });

    test('查词时画面 + 挪过封面帧 → 按时刻抽（subtitleStart）', () {
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.gif,
          overrides: const MiningRequestOverrides(
            videoImageMode: 'current_frame',
            coverFrameAtMs: 11042,
          ),
        ),
        VideoMiningImageMode.subtitleStart,
      );
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.currentFrame,
          overrides: const MiningRequestOverrides(
            videoImageMode: 'current_frame',
          ),
        ),
        VideoMiningImageMode.currentFrame,
        reason: '没挪帧时仍是当前（锁住的）画面',
      );
    });

    test('打了码：动图 / 片段改成「字幕开头」静帧，静态方式不变', () {
      const List<MiningMosaicRegion> mosaic = <MiningMosaicRegion>[
        MiningMosaicRegion(left: 0.1, top: 0.1, right: 0.3, bottom: 0.3),
      ];
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.gif,
          overrides: const MiningRequestOverrides(mosaic: mosaic),
        ),
        VideoMiningImageMode.subtitleStart,
      );
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.gif,
          overrides: const MiningRequestOverrides(
            videoImageMode: 'video_clip',
            mosaic: mosaic,
          ),
        ),
        VideoMiningImageMode.subtitleStart,
      );
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.currentFrame,
          overrides: const MiningRequestOverrides(mosaic: mosaic),
        ),
        VideoMiningImageMode.currentFrame,
        reason: '查词时画面本就是静图（锁住的那一帧）',
      );
    });

    test('forceSubtitleStart 仍作用于覆盖后的值', () {
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.gif,
          overrides: const MiningRequestOverrides(
            videoImageMode: 'current_frame',
          ),
          forceSubtitleStart: true,
        ),
        VideoMiningImageMode.subtitleStart,
      );
      expect(
        resolveVideoMiningImageMode(
          preferred: VideoMiningImageMode.currentFrame,
          forceSubtitleStart: true,
        ),
        VideoMiningImageMode.subtitleStart,
      );
    });
  });

  group('对话框图片分区', () {
    test('没有时间窗只剩查词时画面', () {
      expect(
        advancedMiningVideoImageModes(
          hasClipWindow: false,
          hasMediaSource: true,
          templateRendersClip: true,
        ),
        <VideoMiningImageMode>[VideoMiningImageMode.currentFrame],
      );
    });

    test('模板确定不渲染片段 / 没有可裁的源时去掉片段；判定不了时保留', () {
      expect(
        advancedMiningVideoImageModes(
          hasClipWindow: true,
          hasMediaSource: true,
          templateRendersClip: false,
        ),
        isNot(contains(VideoMiningImageMode.videoClip)),
      );
      expect(
        advancedMiningVideoImageModes(
          hasClipWindow: true,
          hasMediaSource: false,
          templateRendersClip: true,
        ),
        isNot(contains(VideoMiningImageMode.videoClip)),
      );
      expect(
        advancedMiningVideoImageModes(
          hasClipWindow: true,
          hasMediaSource: true,
          templateRendersClip: null,
        ),
        contains(VideoMiningImageMode.videoClip),
      );
    });

    test('默认方式：设置值不可选时取引擎同样情况下会出的那种', () {
      final List<VideoMiningImageMode> noClip = advancedMiningVideoImageModes(
        hasClipWindow: true,
        hasMediaSource: true,
        templateRendersClip: false,
      );
      expect(
        advancedMiningDefaultVideoImageMode(
          VideoMiningImageMode.videoClip,
          noClip,
        ),
        VideoMiningImageMode.gif,
      );
      expect(
        advancedMiningDefaultVideoImageMode(
          VideoMiningImageMode.subtitleStart,
          noClip,
        ),
        VideoMiningImageMode.subtitleStart,
      );
      expect(
        advancedMiningDefaultVideoImageMode(
          VideoMiningImageMode.gif,
          const <VideoMiningImageMode>[VideoMiningImageMode.currentFrame],
        ),
        VideoMiningImageMode.currentFrame,
      );
    });

    test('逐帧步长：按容器帧率，读不到按 24fps', () {
      expect(videoFrameStepMsForFps(23.976), 42);
      expect(videoFrameStepMsForFps(60), 17);
      expect(videoFrameStepMsForFps(null), 42);
      expect(videoFrameStepMsForFps(0), 42);
      expect(videoFrameStepMsForFps(double.nan), 42);
    });

    test('对话框副本覆盖整段写卡窗口才交给引擎', () {
      expect(
        advancedMiningSnapshotCovers(
          coveredStartMs: 7880,
          coveredEndMs: 17620,
          clipStartMs: 10880,
          clipEndMs: 14620,
          stillFrameAtMs: 11000,
        ),
        isTrue,
      );
      expect(
        advancedMiningSnapshotCovers(
          coveredStartMs: 7880,
          coveredEndMs: 17620,
          clipStartMs: 10880,
          clipEndMs: 19000,
          stillFrameAtMs: 11000,
        ),
        isFalse,
        reason: '对话框里加了后一句，窗口超出副本',
      );
      expect(
        advancedMiningSnapshotCovers(
          coveredStartMs: 7880,
          coveredEndMs: 17620,
          clipStartMs: 10880,
          clipEndMs: 14620,
          stillFrameAtMs: 7000,
        ),
        isFalse,
        reason: '静帧时刻在副本之前',
      );
    });
  });
}
