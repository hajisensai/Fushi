import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookUid = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  group('VideoPlayerController cue sync', () {
    test('selects cue by position; gap keeps previous; notifies on change', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int notifications = 0;
      c.addListener(() => notifications++);

      c.debugUpdateCueForPosition(500);
      expect(c.currentCueIndex, 0);
      expect(c.currentCue!.text, 'line0');

      c.debugUpdateCueForPosition(1500); // gap：保留 cue0
      expect(c.currentCueIndex, 0);

      c.debugUpdateCueForPosition(2500);
      expect(c.currentCueIndex, 1);
      expect(c.currentCue!.text, 'line1');

      c.debugUpdateCueForPosition(2600); // 同句不重复通知
      expect(c.currentCueIndex, 1);

      expect(notifications, 2);
    });

    test('delayMs offsets cue lookup', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000)]);
      c.setDelayMs(600);
      c.debugUpdateCueForPosition(1500); // 1500-600=900 命中 cue0
      expect(c.currentCueIndex, 0);
    });
  });

  group('VideoPlayerController audio track mapping', () {
    test('currentAudioStreamIndex is null before load (no player)', () {
      // 未 load 时无 libmpv player：制卡裁音频走 ffmpeg 默认音轨（不加 -map）。
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(c.currentAudioStreamIndex, isNull);
      // audioTracks 同样为空（与 -map 决策一致）。
      expect(c.audioTracks, isEmpty);
    });
  });
}
