import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int start, int end, String text) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'k'
  ..sentenceIndex = start
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0;

void main() {
  test('未 load 的 controller 经外部播放态驱动位置 / 播放中 / 时长 / 当前 cue', () {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    expect(c.positionMs, isNull, reason: '无 Player 也无外部态：位置未知');
    expect(c.isPlaying, isFalse);
    c.setCues(<AudioCue>[_cue(1000, 2000, 'a'), _cue(3000, 4000, 'b')]);

    int notifications = 0;
    c.addListener(() => notifications++);

    c.applyExternalPlaybackState(
      positionMs: 1500,
      playing: true,
      durationMs: 90000,
    );
    expect(c.positionMs, 1500);
    expect(c.isPlaying, isTrue);
    expect(c.durationMs, 90000);
    expect(c.currentCueIndex, 0);
    expect(c.currentCue?.text, 'a');
    expect(notifications, greaterThan(0));

    final int before = notifications;
    c.applyExternalPlaybackState(positionMs: 1600, playing: true);
    expect(c.currentCueIndex, 0);
    expect(notifications, before, reason: '同 cue、同播放态、时长未变：不通知');
    expect(c.durationMs, 90000, reason: 'durationMs null = 保持上次值');

    c.applyExternalPlaybackState(positionMs: 3500, playing: false);
    expect(c.currentCueIndex, 1);
    expect(c.isPlaying, isFalse);
    expect(notifications, greaterThan(before));
  });

  test('外部位置流入 effectivePositionMs（字幕淡变 / 面板跟随读的是它）', () {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.applyExternalPlaybackState(positionMs: 2500, playing: true);
    expect(c.effectivePositionMs, 2500);
  });
}
