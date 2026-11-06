// Dbd86l4kA-（所有者 2026-10-27 拍板）：暂停时按「重播当前句 / 重播上一句」一律起播；
// 单纯「跳到上 / 下一句」保持当前播放 / 暂停态不变。
//
// 控制器层：[VideoPlayerController.playFromCue] / [playFromPreviousCue] 起播，
// [skipToCue] / [skipToPrevCue] / [skipToNextCue] 不起播；页面层：两个重播入口走前者。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

VideoPlayerController _controller(List<String> actions) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[
    _cue(0, 0, 1000),
    _cue(1, 2000, 3000),
    _cue(2, 4000, 5000),
  ]);
  c.debugSetSubtitleEndHoldHooksForTesting(
    isPlaying: () => false,
    onPause: () async => actions.add('pause'),
    onPlay: () async => actions.add('play'),
  );
  return c;
}

void main() {
  test('重播当前句：跳到句首并起播，不挂句尾停', () async {
    final List<String> actions = <String>[];
    final VideoPlayerController c = _controller(actions);
    addTearDown(c.dispose);
    c.debugSetPositionForTesting(2500);
    await c.playFromCue(c.cues[1]);
    expect(actions, <String>['play']);
    expect(c.debugOneShotHoldCueIndex, isNull, reason: '页面重播播完照常往下走');
  });

  test('重播上一句：按上一句判据定位并起播；已是首句时 no-op 不起播', () async {
    final List<String> actions = <String>[];
    final VideoPlayerController c = _controller(actions);
    addTearDown(c.dispose);
    c.debugSetPositionForTesting(4500);
    await c.playFromPreviousCue();
    expect(actions, <String>['play']);

    actions.clear();
    final VideoPlayerController first = _controller(actions);
    addTearDown(first.dispose);
    first.debugSetPositionForTesting(500);
    await first.playFromPreviousCue();
    expect(actions, isEmpty);
  });

  test('单纯跳句保持播放态：skipToCue / skipToPrevCue / skipToNextCue 不起播', () async {
    final List<String> actions = <String>[];
    final VideoPlayerController c = _controller(actions);
    addTearDown(c.dispose);
    c.debugSetPositionForTesting(2500);
    await c.skipToCue(c.cues[1]);
    await c.skipToPrevCue();
    await c.skipToNextCue();
    expect(actions, isEmpty);
  });

  test('视频页两个重播入口走起播版本', () {
    final String src = readVideoFushiSource();
    final String current = methodBody(
      src,
      'Future<void> _replayCurrentCueAndKeepControls(',
    );
    expect(current.contains('_controller?.playFromCue(cue)'), isTrue);
    final String previous = methodBody(
      src,
      'Future<void> _replayPreviousCueAndKeepControls(',
    );
    expect(previous.contains('_controller?.playFromPreviousCue()'), isTrue);
  });
}
