// 高级制卡「句子音频」试听的毫秒级一次性停（[VideoPlayerController.playRangeMs]）。
//
// 与「重播本句」（video_player_replay_cue_test.dart）同一套生命周期：用户主动 seek /
// 换片即作废；但终点是任意毫秒（含首尾留白、起止微调），不是 cue 边界。另两条易回归的
// 线：刚 seek 回起点时滞后的旧位置不能被当成「已到终点」；区间内跨过的 cue 句尾不停。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/range_playback.dart';
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
  group('VideoPlayerController.playRangeMs', () {
    late VideoPlayerController c;
    late List<String> actions;

    setUp(() {
      c = VideoPlayerController();
      actions = <String>[];
      c.setCues(<AudioCue>[
        _cue(0, 1000, 2000),
        _cue(1, 2100, 3000),
        _cue(2, 3100, 4000),
      ]);
      c.debugSetSubtitleEndHoldHooksForTesting(
        isPlaying: () => true,
        onPause: () async => actions.add('pause'),
        onSeek: (int positionMs) async => actions.add('seek:$positionMs'),
        onPlay: () async => actions.add('play'),
      );
      // 位置调和（seek 在途）按真实播放态判：试听起播后就是播放态。
      c.debugSetIsPlayingForTesting(true);
    });
    tearDown(() => c.dispose());

    test('播到终点（任意毫秒，越过 cue 边界）暂停一次并消耗', () async {
      await c.playRangeMs(880, 3270);
      expect(actions, <String>['play'], reason: '试听必须主动起播');
      expect(c.debugPlayRangeUntilMs, 3270);

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(2050);
      c.debugUpdateCueForPosition(3100);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play'], reason: '区间内（含跨过两条 cue 的句尾）不停');

      c.debugUpdateCueForPosition(3280);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play', 'pause']);
      expect(c.debugPlayRangeUntilMs, isNull, reason: '停下即消耗');

      c.debugUpdateCueForPosition(3500);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play', 'pause'], reason: '一次性，不会再停');
    });

    test('刚 seek 回起点时滞后的旧位置（已越过终点）不触发暂停', () async {
      // 上一次试听停在区间终点之后；这次从起点重放，seek 落地前 tick 仍报旧位置。
      await c.playRangeMs(1000, 2500);
      c.debugUpdateCueForPosition(2600);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play'], reason: 'seek 在途：旧位置被调和成目标起点');
      expect(c.debugPlayRangeUntilMs, 2500);

      c.debugUpdateCueForPosition(1010);
      c.debugUpdateCueForPosition(2510);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['play', 'pause']);
    });

    test('用户主动 seek / 换片作废终点', () async {
      await c.playRangeMs(1000, 2500);
      await c.seekMs(5000);
      expect(c.debugPlayRangeUntilMs, isNull, reason: 'seekMs 作废');

      await c.playRangeMs(1000, 2500);
      c.setCues(<AudioCue>[_cue(0, 0, 500)]);
      expect(c.debugPlayRangeUntilMs, isNull, reason: 'setCues（换片 / 换字幕）作废');

      await c.playRangeMs(1000, 2500);
      await c.skipToCue(c.cues.first);
      expect(c.debugPlayRangeUntilMs, isNull, reason: '跳到别的句（_rawSeekMs）作废');
    });

    test('stopPlayRange 作废终点：之后自然续播不会在旧终点被停', () async {
      await c.playRangeMs(1000, 2500);
      await c.stopPlayRange();
      expect(c.debugPlayRangeUntilMs, isNull);
      c.debugUpdateCueForPosition(1010);
      c.debugUpdateCueForPosition(2600);
      await Future<void>.delayed(Duration.zero);
      expect(actions.where((String a) => a == 'pause'), isEmpty);
    });

    test('空区间不起播', () async {
      final RangePlayback playback = await c.playRangeMs(2000, 2000);
      expect(actions, isEmpty);
      expect(c.debugPlayRangeUntilMs, isNull);
      expect(playback.isEnded, isTrue, reason: '没有可播的，句柄直接是结束态');
    });
  });

  // BUG-3801 / FDN66-xurt：区间播完要能被调用方观察到（试听按钮据此复位），否则
  // 播完后按钮停在「停止」，下一次点击只是去停。
  group('VideoPlayerController.playRangeMs 的结果句柄', () {
    late VideoPlayerController c;
    late List<String> actions;

    setUp(() {
      c = VideoPlayerController();
      actions = <String>[];
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 2100, 3000)]);
      c.debugSetSubtitleEndHoldHooksForTesting(
        isPlaying: () => true,
        onPause: () async => actions.add('pause'),
        onSeek: (int positionMs) async => actions.add('seek:$positionMs'),
        onPlay: () async => actions.add('play'),
      );
      c.debugSetIsPlayingForTesting(true);
    });
    tearDown(() => c.dispose());

    Future<RangePlaybackEnd?> settled(RangePlayback p) async {
      await Future<void>.delayed(Duration.zero);
      if (!p.isEnded) return null;
      return p.ended;
    }

    test('播到终点：句柄以 reachedEnd 完成（与那次自动暂停同一刻）', () async {
      final RangePlayback p = await c.playRangeMs(1000, 2500);
      c.debugUpdateCueForPosition(1010);
      expect(await settled(p), isNull, reason: '区间内仍在播');
      c.debugUpdateCueForPosition(2510);
      expect(await settled(p), RangePlaybackEnd.reachedEnd);
      expect(actions, <String>['play', 'pause']);
    });

    test(
      'stopPlayRange / seek / 换片 / 跳句 / 下一段 / 销毁：句柄以 interrupted 完成',
      () async {
        final RangePlayback stopped = await c.playRangeMs(1000, 2500);
        await c.stopPlayRange();
        expect(await settled(stopped), RangePlaybackEnd.interrupted);

        final RangePlayback seeked = await c.playRangeMs(1000, 2500);
        await c.seekMs(5000);
        expect(await settled(seeked), RangePlaybackEnd.interrupted);

        final RangePlayback recued = await c.playRangeMs(1000, 2500);
        c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 2100, 3000)]);
        expect(await settled(recued), RangePlaybackEnd.interrupted);

        final RangePlayback skipped = await c.playRangeMs(1000, 2500);
        await c.skipToCue(c.cues.last);
        expect(await settled(skipped), RangePlaybackEnd.interrupted);

        final RangePlayback first = await c.playRangeMs(1000, 2500);
        final RangePlayback second = await c.playRangeMs(1200, 2600);
        expect(await settled(first), RangePlaybackEnd.interrupted);
        expect(second.isEnded, isFalse, reason: '新一段不受上一段收尾影响');

        final VideoPlayerController other = VideoPlayerController()
          ..debugSetSubtitleEndHoldHooksForTesting(
            isPlaying: () => true,
            onPause: () async {},
            onPlay: () async {},
          );
        final RangePlayback disposed = await other.playRangeMs(1000, 2500);
        other.dispose();
        expect(await settled(disposed), RangePlaybackEnd.interrupted);
      },
    );

    test('媒体在终点前播完：句柄以 reachedEnd 完成', () async {
      final StreamController<bool> completed = StreamController<bool>();
      addTearDown(completed.close);
      await c.debugAttachCompletedStreamForTesting(completed.stream);
      final RangePlayback p = await c.playRangeMs(1000, 999999);
      completed.add(true);
      expect(await settled(p), RangePlaybackEnd.reachedEnd);
      expect(c.debugPlayRangeUntilMs, isNull);
    });
  });
}
