// 查词浮层顶栏「重播本句」的一次性句尾暂停（[VideoPlayerController.replayCue]）。
//
// 核心不变量：一次性 hold 与全局偏好「字幕结束暂停」（[setPauseAtSubtitleEnd]）**正交**
// ——重播不改写偏好，偏好也不改写重播；两者共用同一套句尾判定与落点。
//
// 另一条易回归的线是**生命周期**：一次性 hold 绝不能挂进 `_clearSeekTargetSnap`（自然
// 播放越过目标句时播放器自己会调它，那正是最需要 hold 存活的一刻），只在用户主动改变
// 播放位置（seekMs / skipToCue）与换片（setCues）时作废。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

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
  group('VideoPlayerController.replayCue 一次性句尾暂停', () {
    test('全局偏好关着时，重播那一句仍在句尾停一次（直接进下一句路径）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      final List<String> actions = <String>[];
      c.debugSetPauseAtSubtitleEndForTesting(
        // 关键：全局偏好**关着**。停下来只能是一次性 hold 的功劳。
        enabled: false,
        isPlaying: () => true,
        onPause: () async => actions.add('pause'),
        onSeek: (int positionMs) async => actions.add('seek:$positionMs'),
        onPlay: () async => actions.add('play'),
      );

      await c.replayCue(c.cues[0]);
      expect(actions, <String>['play'], reason: '重播必须主动起播');
      expect(c.debugOneShotHoldCueIndex, 0);

      c.debugUpdateCueForPosition(900);
      expect(actions, <String>['play'], reason: '句中不停');

      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play', 'pause', 'seek:1000'],
          reason: '越过句尾：暂停并回到该句的精确结尾');
      expect(c.debugOneShotHoldCueIndex, isNull, reason: '停下即消耗');
    });

    test('全局偏好关着时，句尾落进 gap 也停（gap 路径）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      // cue0 与 cue1 之间是静音 gap，句尾后下一拍无 cue。
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      c.debugUpdateCueForPosition(500);
      expect(pauses, 0);

      c.debugUpdateCueForPosition(1500);
      expect(pauses, 1, reason: 'gap 路径同样要停');
      expect(c.debugOneShotHoldCueIndex, isNull);

      // 消耗后继续播，后面的句子不受影响（偏好仍是关着的）。
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3500);
      expect(pauses, 1, reason: '一次性 hold 不得升级成全局「每句都停」');
    });

    test('重播不写全局偏好：别的句子照常播过去', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue(0, 0, 1000),
        _cue(1, 1001, 2000),
        _cue(2, 2001, 3000),
      ]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      // 重播 cue1（不是第一句，验证下标解析而非「恰好是 0」）。
      await c.replayCue(c.cues[1]);
      expect(c.debugOneShotHoldCueIndex, 1);

      c.debugUpdateCueForPosition(1500);
      c.debugUpdateCueForPosition(2100);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1, reason: '只有被重播的 cue1 在句尾停');

      // cue2 结束时不该再停。
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3500);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1);
    });

    test('自然播回同一句不再停（停下即消耗，不是永久循环）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1);

      // 用户按播放继续；再次走过 cue0 的句尾时不该被停第二次。
      c.debugUpdateCueForPosition(500);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1, reason: '一次性 hold 已被消耗');
    });

    test('用户中途拖进度条（seekMs）作废一次性 hold', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      expect(c.debugOneShotHoldCueIndex, 0);

      await c.seekMs(300);
      expect(c.debugOneShotHoldCueIndex, isNull,
          reason: '主动改变播放位置 = 放弃「停在本句尾」的意图');

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 0);
    });

    test('跳去别的句（skipToCue）作废一次性 hold', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      await c.skipToCue(c.cues[1]);
      expect(c.debugOneShotHoldCueIndex, isNull);

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 0);
    });

    test('换字幕/换片（setCues）清掉一次性 hold（旧下标对新列表无意义）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      expect(c.debugOneShotHoldCueIndex, 0);

      c.setCues(<AudioCue>[_cue(0, 0, 5000), _cue(1, 5001, 9000)]);
      expect(c.debugOneShotHoldCueIndex, isNull);

      c.debugUpdateCueForPosition(2000);
      c.debugUpdateCueForPosition(5500);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 0, reason: '新片的句子不得被上一片的 hold 停住');
    });

    test('全局偏好开着时重播同一句仍能停（防重复停记号被重播复位）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        // 偏好开着：cue0 已经被句尾暂停过一次，记号停在 cue0 上。
        enabled: true,
        isPlaying: () => true,
        onPause: () async => pauses++,
      );

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1);

      // 用户在查词浮层里点「重播本句」：必须再停一次，而不是被「这句停过了」挡掉。
      await c.replayCue(c.cues[0]);
      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 2, reason: '重播复位了防重复停记号');
    });

    test('暂停态不停：句尾判定只对真正在播的情形生效', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        // 用户重播后立刻手动按了暂停：位置不再前进，任何越界都是别的原因造成的。
        isPlaying: () => false,
        onPause: () async => pauses++,
      );

      await c.replayCue(c.cues[0]);
      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 0);
    });

    test('cue 不在当前列表时退化为「跳过去接着播」，不假装能停', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      final List<String> actions = <String>[];
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: false,
        isPlaying: () => true,
        onPause: () async => actions.add('pause'),
        onPlay: () async => actions.add('play'),
      );

      // 换轨/换片竞态：手上的 cue 已不属于当前列表。
      await c.replayCue(_cue(9, 90000, 91000));
      expect(actions, <String>['play']);
      expect(c.debugOneShotHoldCueIndex, isNull);
    });
  });
}
