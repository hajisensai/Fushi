// 视频逐句学习工具（副屏 S6）：重播本句后暂停、每句播完自动暂停、循环当前句 N 次、
// A-B 循环。
//
// 控制器层钉死状态机：自动暂停与一次性「播完就停」走同一套句尾判定（相邻句 / gap 两条
// 路径，同一句不停两次）；循环开着时自动暂停让位，有限次数用完的最后一遍照常往下（自动
// 暂停开着就停在句尾）；A-B 只在自然播放越过 B 时回绕 A，显式 seek 撤武装，换片作废。
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

({VideoPlayerController c, List<String> actions}) _setUp({
  bool playing = true,
  List<AudioCue>? cues,
}) {
  final List<String> actions = <String>[];
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(
    cues ??
        <AudioCue>[
          _cue(0, 0, 1000),
          _cue(1, 2000, 3000),
          _cue(2, 3000, 4000),
          _cue(3, 6000, 7000),
        ],
  );
  c.debugSetSubtitleEndHoldHooksForTesting(
    isPlaying: () => playing,
    onPause: () async => actions.add('pause'),
    onSeek: (int ms) async => actions.add('seek:$ms'),
    onPlay: () async => actions.add('play'),
  );
  return (c: c, actions: actions);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('每句播完自动暂停', () {
    test('相邻下一句：越过句尾暂停并落回句尾；续播走到下一句句尾再停', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.setAutoPauseAtCueEnd(true);
      expect(c.autoPauseAtCueEnd, isTrue);
      c.debugUpdateCueForPosition(2500); // cue1
      c.debugUpdateCueForPosition(3100); // 越过 cue1 句尾进入首尾相接的 cue2
      await _flush();
      expect(actions, <String>['pause', 'seek:3000']);

      actions.clear();
      // 落点 = cue1 句尾；续播进入 cue2，cue2 播完落进 gap → 再停。
      c.debugUpdateCueForPosition(3000);
      c.debugUpdateCueForPosition(3500);
      c.debugUpdateCueForPosition(4200);
      await _flush();
      expect(actions, <String>['pause']);
    });

    test('句尾落进 gap：停一次，同一句不停第二次', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.setAutoPauseAtCueEnd(true);
      c.debugUpdateCueForPosition(6500); // cue3
      c.debugUpdateCueForPosition(7200); // gap（末句之后）
      await _flush();
      expect(actions, <String>['pause']);
      actions.clear();
      c.debugUpdateCueForPosition(7400);
      await _flush();
      expect(actions, isEmpty);
    });

    test('相邻路径停过的句子续播落进 gap 不再停', () async {
      // cue0 后紧接 cue1（一拍跨过短 gap 直接进下一句 → 相邻路径落回 cue0 句尾）。
      final (:VideoPlayerController c, :List<String> actions) = _setUp(
        cues: <AudioCue>[_cue(0, 0, 1000), _cue(1, 1100, 2000)],
      );
      addTearDown(c.dispose);
      c.setAutoPauseAtCueEnd(true);
      c.debugUpdateCueForPosition(500);
      c.debugUpdateCueForPosition(1200); // 一拍跨进 cue1
      await _flush();
      expect(actions, <String>['pause', 'seek:1000']);
      actions.clear();
      c.debugUpdateCueForPosition(1000); // 落点（cue0 句尾，仍在 cue0 内）
      c.debugUpdateCueForPosition(1050); // 续播落进 gap
      await _flush();
      expect(actions, isEmpty, reason: 'cue0 已停过');
    });

    test('关着：照常往下播', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100);
      c.debugUpdateCueForPosition(4200);
      await _flush();
      expect(actions, isEmpty);
    });

    test('循环当前句开着时让位给循环', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.setAutoPauseAtCueEnd(true);
      c.setLoopCurrentCue(true);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100);
      await _flush();
      expect(actions, isNot(contains('pause')));
      expect(c.seekGeneration, gen0 + 1, reason: '回绕');
    });

    test('开关只在翻转时通知', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      int notified = 0;
      c.addListener(() => notified++);
      c.setAutoPauseAtCueEnd(true);
      c.setAutoPauseAtCueEnd(true);
      c.setAutoPauseAtCueEnd(false);
      expect(notified, 2);
    });
  });

  group('循环当前句 N 次', () {
    test('回绕 N 次，最后一次回绕时关掉循环、之后照常往下播', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.startCueLoop(times: 2);
      expect(c.loopCurrentCue, isTrue);
      expect(c.loopRepeatsRemaining, 2);
      expect(c.loopRepeatTimes, 2);
      final int gen0 = c.seekGeneration;

      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100); // 第 1 次回绕
      expect(c.seekGeneration, gen0 + 1);
      expect(c.loopRepeatsRemaining, 1);
      expect(c.loopRepeatTimes, 2, reason: 'N 不随回绕变');

      c.debugUpdateCueForPosition(2100);
      c.debugUpdateCueForPosition(3100); // 第 2 次（最后一次）回绕
      expect(c.seekGeneration, gen0 + 2);
      expect(c.loopCurrentCue, isFalse);
      expect(c.loopRepeatsRemaining, isNull);
      expect(c.loopRepeatTimes, isNull);

      c.debugUpdateCueForPosition(2100);
      c.debugUpdateCueForPosition(3100); // 最后一遍播完：不再回绕
      expect(c.seekGeneration, gen0 + 2);
    });

    test('最后一遍播完时自动暂停接手', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.setAutoPauseAtCueEnd(true);
      c.startCueLoop(times: 1);
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100); // 唯一一次回绕
      await _flush();
      expect(actions, isNot(contains('pause')));
      c.debugUpdateCueForPosition(2100);
      c.debugUpdateCueForPosition(3100);
      await _flush();
      expect(actions, contains('pause'));
    });

    test('times <= 0 = 无限；setLoopCurrentCue 清掉次数', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.startCueLoop(times: 3);
      expect(c.loopRepeatsRemaining, 3);
      c.startCueLoop();
      expect(c.loopCurrentCue, isTrue);
      expect(c.loopRepeatsRemaining, isNull);
      c.startCueLoop(times: 5);
      c.setLoopCurrentCue(true);
      expect(c.loopRepeatsRemaining, isNull, reason: '回到无限');
      c.stopCueLoop();
      expect(c.loopCurrentCue, isFalse);
    });

    test('无限循环一直回绕', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.startCueLoop();
      final int gen0 = c.seekGeneration;
      for (int i = 1; i <= 4; i++) {
        c.debugUpdateCueForPosition(2500);
        c.debugUpdateCueForPosition(3100);
        expect(c.seekGeneration, gen0 + i);
      }
      expect(c.loopCurrentCue, isTrue);
    });
  });

  group('重播本句后暂停', () {
    test('句中：重播当前句，句尾停', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.debugUpdateCueForPosition(2500); // cue1
      await c.replayCurrentCueThenPause();
      expect(c.debugOneShotHoldCueIndex, 1);
      expect(actions, contains('play'));
      actions.clear();
      c.debugUpdateCueForPosition(2100);
      c.debugUpdateCueForPosition(3100);
      await _flush();
      expect(actions, contains('pause'));
    });

    test('句间 gap：取位置之前最近的一句', () async {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.debugSetPositionForTesting(5000); // cue2 与 cue3 之间
      c.debugUpdateCueForPosition(5000);
      expect(c.currentCueIndex, -1);
      await c.replayCurrentCueThenPause();
      expect(c.debugOneShotHoldCueIndex, 2);
    });

    test('无字幕：no-op', () async {
      final List<String> actions = <String>[];
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetSubtitleEndHoldHooksForTesting(
        onPause: () async => actions.add('pause'),
        onPlay: () async => actions.add('play'),
      );
      await c.replayCurrentCueThenPause();
      expect(actions, isEmpty);
    });
  });

  group('A-B 循环', () {
    test('三态切换：标 A → 标 B 开始循环 → 清除', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.debugSetPositionForTesting(1000);
      expect(c.toggleAbLoop(), isTrue);
      expect(c.abLoopA, const Duration(milliseconds: 1000));
      expect(c.abLoopB, isNull);
      expect(c.abLoopActive, isFalse);

      c.debugSetPositionForTesting(800);
      expect(c.toggleAbLoop(), isFalse, reason: 'B 不晚于 A：忽略，仍等 B');
      expect(c.abLoopB, isNull);

      c.debugSetPositionForTesting(4000);
      expect(c.toggleAbLoop(), isTrue);
      expect(c.abLoopB, const Duration(milliseconds: 4000));
      expect(c.abLoopActive, isTrue);

      expect(c.toggleAbLoop(), isTrue);
      expect(c.abLoopA, isNull);
      expect(c.abLoopB, isNull);
    });

    test('自然播放越过 B 回到 A；暂停中不回绕', () async {
      bool playing = true;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetSubtitleEndHoldHooksForTesting(
        isPlaying: () => playing,
        onPause: () async {},
      );
      c.debugSetPositionForTesting(1000);
      c.setAbLoopA();
      c.debugSetPositionForTesting(4000);
      c.setAbLoopB();
      c.debugSetPositionForTesting(null);

      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(3900);
      c.debugUpdateCueForPosition(4100);
      expect(c.seekGeneration, gen0 + 1);
      expect(c.resumePositionMs, 1000);
      await _flush();

      // seek 在途的滞后 tick 不连发回绕。
      c.debugUpdateCueForPosition(4200);
      expect(c.seekGeneration, gen0 + 1);

      // 落到 A、进入区间重新武装；暂停中越过 B 不回绕。
      c.debugUpdateCueForPosition(1000);
      c.debugUpdateCueForPosition(2000);
      playing = false;
      c.debugUpdateCueForPosition(4100);
      expect(c.seekGeneration, gen0 + 1);
    });

    test('显式 seek 到 B 之后不被拽回，回到区间内重新生效', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetSubtitleEndHoldHooksForTesting(
        isPlaying: () => true,
        onPause: () async {},
      );
      c.debugSetPositionForTesting(1000);
      c.setAbLoopA();
      c.debugSetPositionForTesting(4000);
      c.setAbLoopB();
      c.debugSetPositionForTesting(null);

      c.debugUpdateCueForPosition(2000); // 武装
      await c.seekMs(8000);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(8000);
      c.debugUpdateCueForPosition(8200);
      expect(c.seekGeneration, gen0, reason: '用户 seek 走了，不回绕');

      // 进度条拖动（只有 clearSeekTargetSnap 信号）同样撤武装。
      c.debugUpdateCueForPosition(2000);
      c.clearSeekTargetSnap();
      c.debugUpdateCueForPosition(5000);
      expect(c.seekGeneration, gen0);
    });

    test('只有 A 时不循环；setAbLoopB 没有 A 时拒绝；clearAbLoop 无端点返回 false', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetSubtitleEndHoldHooksForTesting(
        isPlaying: () => true,
        onPause: () async {},
      );
      c.debugSetPositionForTesting(3000);
      expect(c.setAbLoopB(), isFalse);
      expect(c.clearAbLoop(), isFalse);
      c.setAbLoopA();
      c.debugSetPositionForTesting(null);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(3500);
      c.debugUpdateCueForPosition(9000);
      expect(c.seekGeneration, gen0);
      expect(c.clearAbLoop(), isTrue);
    });
  });
}
