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

  group('VideoPlayerController settings getters (no player)', () {
    test('delayMs getter reflects setDelayMs and clamps to ±600000', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(c.delayMs, 0);
      c.setDelayMs(250);
      expect(c.delayMs, 250);
      c.setDelayMs(-50);
      expect(c.delayMs, -50);
      c.setDelayMs(10000000);
      expect(c.delayMs, 600000);
      c.setDelayMs(-10000000);
      expect(c.delayMs, -600000);
    });

    test('speed getter falls back to last setSpeed when no player', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(c.speed, 1.0);
      await c.setSpeed(1.5);
      // 未 load（无 player）时 speed 回退到 _lastSpeed。
      expect(c.speed, 1.5);
    });

    test('positionMs is null before load', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(c.positionMs, isNull);
    });
  });

  group('VideoPlayerController flushPosition', () {
    test('is a no-op (no write) before load — no player, no bookUid', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      await c.flushPosition();
      expect(writes, isEmpty,
          reason: 'no player/bookUid before load → nothing to flush');
    });

    test('dispose does not write a position before load', () async {
      final c = VideoPlayerController();
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      c.dispose();
      // Give any (incorrectly) scheduled fire-and-forget write a chance to run.
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
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
