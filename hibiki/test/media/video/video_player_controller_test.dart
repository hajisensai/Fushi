import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

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
  group('VideoPlayerController cue sync', () {
    test('selects cue by position; gap clears subtitle; notifies on change',
        () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int notifications = 0;
      c.addListener(() => notifications++);

      c.debugUpdateCueForPosition(500);
      expect(c.currentCueIndex, 0);
      expect(c.currentCue!.text, 'line0');

      c.debugUpdateCueForPosition(1500); // gap：字幕消失（BUG-074）
      expect(c.currentCueIndex, -1);
      expect(c.currentCue, isNull);

      c.debugUpdateCueForPosition(2500);
      expect(c.currentCueIndex, 1);
      expect(c.currentCue!.text, 'line1');

      c.debugUpdateCueForPosition(2600); // 同句不重复通知
      expect(c.currentCueIndex, 1);

      // 500→cue0, 1500→clear, 2500→cue1 = 3 次；2600 同句不通知。
      expect(notifications, 3);
    });

    // BUG-074: 视频底部字幕 overlay 与有声书正文跟随高亮语义不同——真实字幕在
    // 其时间窗结束后（句间静音 gap / 末句之后）必须消失，不能保留上一句。
    test(
        'BUG-074: subtitle clears in gap and after last cue; no redundant '
        'notify while gap is sustained', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int notifications = 0;
      c.addListener(() => notifications++);

      c.debugUpdateCueForPosition(500); // cue0 显示
      expect(c.currentCue!.text, 'line0');
      expect(notifications, 1);

      c.debugUpdateCueForPosition(1500); // 句间 gap：清空
      expect(c.currentCue, isNull);
      expect(c.currentCueIndex, -1);
      expect(notifications, 2);

      // gap 内多次 tick 不重复 notify（已无字幕）。
      c.debugUpdateCueForPosition(1600);
      c.debugUpdateCueForPosition(1900);
      expect(c.currentCue, isNull);
      expect(notifications, 2);

      c.debugUpdateCueForPosition(2500); // cue1 显示
      expect(c.currentCue!.text, 'line1');
      expect(notifications, 3);

      c.debugUpdateCueForPosition(3500); // 末句之后：清空
      expect(c.currentCue, isNull);
      expect(c.currentCueIndex, -1);
      expect(notifications, 4);
    });

    test('BUG-074: position before first cue shows no subtitle (no notify)',
        () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 1000, 2000)]);
      int notifications = 0;
      c.addListener(() => notifications++);
      c.debugUpdateCueForPosition(500); // 早于首句：无字幕
      expect(c.currentCue, isNull);
      expect(c.currentCueIndex, -1);
      expect(notifications, 0); // 本就无字幕，不应 notify
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

  group('VideoPlayerController pause at subtitle end', () {
    test('pauses once when leaving the active cue', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int pauses = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: true,
        onPause: () async => pauses++,
      );

      c.debugUpdateCueForPosition(500);
      expect(c.currentCueIndex, 0);
      expect(pauses, 0);

      c.debugUpdateCueForPosition(1500);
      expect(c.currentCueIndex, -1);
      expect(pauses, 1);

      c.debugUpdateCueForPosition(1600);
      c.debugUpdateCueForPosition(1900);
      expect(pauses, 1, reason: 'sustained gap should not pause repeatedly');

      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3500);
      expect(pauses, 2);
    });

    test(
        'pauses at the exact end when playback crosses directly into the next cue',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      final List<String> actions = <String>[];
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: true,
        isPlaying: () => true,
        onPause: () async => actions.add('pause'),
        onSeek: (int positionMs) async => actions.add('seek:$positionMs'),
      );

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);

      expect(actions, <String>['pause', 'seek:1000']);
      expect(c.currentCueIndex, 0,
          reason: 'the completed sentence stays visible at its exact end');

      // The player lands on the previous cue end, then resumes into cue 1.
      // That must not pause cue 0 a second time.
      c.debugUpdateCueForPosition(1000);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>['pause', 'seek:1000']);
      expect(c.currentCueIndex, 1);

      // Rewinding rearms sentence-end pause for a repeated cue.
      c.debugUpdateCueForPosition(500);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);
      expect(actions, <String>[
        'pause',
        'seek:1000',
        'pause',
        'seek:1000',
      ]);
    });

    test('does not snap a paused manual seek back to the previous cue end',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 1001, 2000)]);

      int pauses = 0;
      int seeks = 0;
      c.debugSetPauseAtSubtitleEndForTesting(
        enabled: true,
        isPlaying: () => false,
        onPause: () async => pauses++,
        onSeek: (_) async => seeks++,
      );

      c.debugUpdateCueForPosition(900);
      c.debugUpdateCueForPosition(1125);
      await Future<void>.delayed(Duration.zero);

      expect(pauses, 0);
      expect(seeks, 0);
      expect(c.currentCueIndex, 1);
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

    test('mute toggles without constructing a player and preserves volume',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.setVolume(42);
      expect(c.volume, 42);
      expect(c.muted, isFalse);

      expect(await c.toggleMute(), isTrue);
      expect(c.muted, isTrue);
      expect(c.volume, 42);

      expect(await c.toggleMute(), isFalse);
      expect(c.muted, isFalse);
      expect(c.volume, 42);
    });

    test('adjustVolume accumulates from effective output and clamps', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.setVolume(50);
      expect(await c.adjustVolume(5), 55);
      expect(await c.adjustVolume(5), 60);
      expect(await c.adjustVolume(100), 100);
      expect(await c.adjustVolume(-250), 0);

      await c.setVolume(42);
      await c.toggleMute();
      expect(c.muted, isTrue);
      expect(await c.adjustVolume(5), 5,
          reason: 'volume-up from mute starts at audible zero');
      expect(c.muted, isFalse);
    });

    test('frameStep is a safe no-op before load', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.frameStep(forward: true);
      await c.frameStep(forward: false);
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

  group('着色器对比旁路（B：效果预览/对比）', () {
    test('toggle 旁路翻转、保留启用集，改启用集复位旁路', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      // 无 player 时 applyShaders/setShaderBypass 只记状态、不抛。
      await c.applyShaders(<String>['/s/a.glsl', '/s/b.glsl']);
      expect(c.shaderPaths, <String>['/s/a.glsl', '/s/b.glsl']);
      expect(c.shadersBypassed, isFalse);

      expect(await c.toggleShaderBypass(), isTrue);
      expect(c.shadersBypassed, isTrue);
      // 旁路不改启用集（恢复时贴回）。
      expect(c.shaderPaths, <String>['/s/a.glsl', '/s/b.glsl']);

      expect(await c.toggleShaderBypass(), isFalse);
      expect(c.shadersBypassed, isFalse);

      // 旁路态下改启用集 → 复位为非旁路，按新集生效。
      await c.setShaderBypass(true);
      expect(c.shadersBypassed, isTrue);
      await c.applyShaders(<String>['/s/c.glsl']);
      expect(c.shadersBypassed, isFalse);
      expect(c.shaderPaths, <String>['/s/c.glsl']);
    });
  });
}
