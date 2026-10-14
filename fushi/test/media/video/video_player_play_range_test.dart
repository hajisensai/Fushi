// 高级制卡「句子音频」试听的毫秒级一次性停（[VideoPlayerController.playRangeMs]）。
//
// 与「重播本句」（video_player_replay_cue_test.dart）同一套生命周期：用户主动 seek /
// 换片即作废；但终点是任意毫秒（含首尾留白、起止微调），不是 cue 边界。另两条易回归的
// 线：刚 seek 回起点时滞后的旧位置不能被当成「已到终点」；区间内跨过的 cue 句尾不停。

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
      await c.playRangeMs(2000, 2000);
      expect(actions, isEmpty);
      expect(c.debugPlayRangeUntilMs, isNull);
    });
  });
}
