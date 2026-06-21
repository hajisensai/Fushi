import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:media_kit/media_kit.dart';
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

  group('VideoPlayerController completed stream auto-advance hook', () {
    test('completed=false is ignored; completed=true fires once per load', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      int completed = 0;
      c.setOnCompleted(() => completed++);

      c.debugHandleCompletedForTesting(false);
      expect(completed, 0);

      c.debugHandleCompletedForTesting(true);
      c.debugHandleCompletedForTesting(true);
      expect(completed, 1,
          reason: 'a single media load must not auto-advance more than once');
    });

    test('a new load rearms completed=true', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      int completed = 0;
      c.setOnCompleted(() => completed++);

      c.debugHandleCompletedForTesting(true);
      c.debugResetCompletedForNewLoadForTesting();
      c.debugHandleCompletedForTesting(true);

      expect(completed, 2,
          reason: 'episode reload must allow the next EOF to advance again');
    });

    test('replacing the completed stream cancels the previous subscription',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<bool> first = StreamController<bool>();
      final StreamController<bool> second = StreamController<bool>();
      addTearDown(first.close);
      addTearDown(second.close);
      int completed = 0;
      c.setOnCompleted(() => completed++);

      await c.debugAttachCompletedStreamForTesting(first.stream);
      await c.debugAttachCompletedStreamForTesting(second.stream);
      first.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, 0,
          reason: 'load must cancel the old completed subscription first');

      second.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, 1);
    });

    test('dispose cancels completed subscription and clears callback',
        () async {
      final c = VideoPlayerController();
      final StreamController<bool> stream = StreamController<bool>();
      addTearDown(stream.close);
      int completed = 0;
      c.setOnCompleted(() => completed++);
      await c.debugAttachCompletedStreamForTesting(stream.stream);

      c.dispose();
      stream.add(true);
      await Future<void>.delayed(Duration.zero);

      expect(completed, 0,
          reason: 'completed events after dispose must not call page state');
    });
  });

  group('字幕调轴纯函数 effectiveSubtitlePositionMs', () {
    test('zero offset is identity', () {
      expect(effectiveSubtitlePositionMs(1234, 0), 1234);
    });

    test('positive offset shifts the lookup position back (字幕整体延后)', () {
      // 正偏移＝字幕显得早了 → 往回拨位置，字幕晚出现。
      expect(effectiveSubtitlePositionMs(1500, 600), 900);
    });

    test('negative offset shifts the lookup position forward (字幕提前)', () {
      // 负偏移＝字幕晚于画面 → 往前拨位置，字幕提前。
      expect(effectiveSubtitlePositionMs(1000, -250), 1250);
    });

    test('clamps the lower bound to 0 (位置不为负)', () {
      // posMs - delayMs 为负时夹到 0，不能查出负位置。
      expect(effectiveSubtitlePositionMs(100, 5000), 0);
    });

    test('cue seek target is inverse of effective subtitle position', () {
      // 显示/决策查 cue 用 effective = playerPos - delay；跳到 cue 起点时必须反算
      // 回播放器轴 playerPos = cueStart + delay，否则调轴后按“上一句字幕”会跳到字幕轴
      // 的原始时间点，画面与字幕错位。
      expect(
        VideoPlayerController.cueSeekTargetMs(cueStartMs: 10000, delayMs: 500),
        10500,
      );
      expect(
        VideoPlayerController.cueSeekTargetMs(cueStartMs: 10000, delayMs: -700),
        9300,
      );
      expect(
        VideoPlayerController.cueSeekTargetMs(cueStartMs: 300, delayMs: -1000),
        0,
      );
    });
  });

  group('BUG-259 cue seek 前导余量（句首不被关键帧吸附吃掉）', () {
    test('默认 preRoll=0 时行为不变（与字幕结束暂停精确 seek 同语义）', () {
      // 字幕结束暂停 _pauseAndSeekForSubtitleEnd 用 cueStartMs: cue.endMs + 默认 0 余量，
      // 不能被前导余量影响——否则暂停点被拉回句中。
      expect(
        VideoPlayerController.cueSeekTargetMs(cueStartMs: 10000, delayMs: 0),
        10000,
      );
      expect(
        VideoPlayerController.cueSeekTargetMs(cueStartMs: 10000, delayMs: 500),
        10500,
      );
    });

    test('preRoll 把目标点往前移，吸收 media_kit 关键帧吸附（落点不越过句首）', () {
      // 跳到 10000ms 句首、余量 180ms：请求 seek 到 9820，让关键帧吸附后落回句首附近。
      // 撤掉余量（preRoll=0）会请求 10000，吸附后越过句首 → 漏开头（红）。
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 10000,
          delayMs: 0,
          preRollMs: 180,
        ),
        9820,
      );
    });

    test('实链路：skipToCue 用 kCueSeekPreRollMs 常量（生产值 > 0，落点先于句首）', () {
      // 钉住生产常量本身是正的前导余量：若被改回 0，前导余量整体失效（漏开头回归）。
      expect(VideoPlayerController.kCueSeekPreRollMs, greaterThan(0));
    });

    test('余量减出负值时下界 clamp 到 0', () {
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 100,
          delayMs: 0,
          preRollMs: 180,
        ),
        0,
      );
    });

    test('上一句下界：余量过大不串回前一句（落点钳到上一句起点）', () {
      // 当前句 10000ms、余量 500ms 本会落到 9500；但上一句起点在 9800ms，
      // 落点钳到 9800（不带入上一句尾巴）。
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 10000,
          delayMs: 0,
          preRollMs: 500,
          prevCueStartMs: 9800,
        ),
        9800,
      );
      // 余量没越过上一句起点时按余量落点（10000-180=9820 > 9800）。
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 10000,
          delayMs: 0,
          preRollMs: 180,
          prevCueStartMs: 9800,
        ),
        9820,
      );
    });

    test('前导余量与下界都在 cue 轴上算完后再叠加 delay（逆变换在最后）', () {
      // cue 轴目标 = max(10000-500, 9800) = 9800，再叠加 delay 300 → 10100。
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 10000,
          delayMs: 300,
          preRollMs: 500,
          prevCueStartMs: 9800,
        ),
        10100,
      );
    });

    test('负 preRoll 当 0 处理（防御）', () {
      expect(
        VideoPlayerController.cueSeekTargetMs(
          cueStartMs: 10000,
          delayMs: 0,
          preRollMs: -50,
        ),
        10000,
      );
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

      // toggleMute 返回确定的「切换后有效目标音量」：静音返回 0。
      expect(await c.toggleMute(), 0);
      expect(c.muted, isTrue);
      // 无 player 时 volume getter 回退 _lastVolume；静音不改音量目标，故仍 42。
      expect(c.volume, 42);

      // 取消静音返回静音前音量 42。
      expect(await c.toggleMute(), 42);
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

    // TODO-433：静音真生效 + 独立「静音前音量」字段，根因修复
    // ① 静音期间调音量不污染静音前音量 ② 取消静音恢复到静音前值
    // ③ 静音期间加音量从 0 起、正确解除静音。
    test('toggleMute restores the exact pre-mute volume (TODO-433 bug2)',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.setVolume(73);
      expect(await c.toggleMute(), 0, reason: '进入静音返回有效音量 0');
      expect(c.muted, isTrue);
      // 取消静音必须回到确定的静音前音量 73（不读异步滞后的播放器音量）。
      expect(await c.toggleMute(), 73, reason: '取消静音恢复到静音前音量');
      expect(c.muted, isFalse);
      expect(c.volume, 73);
    });

    test(
        'adjusting volume while muted does not corrupt the pre-mute volume '
        '(TODO-433 bug1)', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.setVolume(80);
      await c.toggleMute();
      expect(c.muted, isTrue);

      // 静音期间「加音量」是合理的「从 0 起音」语义：解除静音并落到 delta。
      expect(await c.adjustVolume(10), 10,
          reason: '静音期间加音量从 0 起 → 正确解除静音并落到 delta');
      expect(c.muted, isFalse, reason: '加非零音量解除静音');

      // 关键：再次静音后取消，恢复值是「最近一次静音前的音量 10」，而非被污染的 80。
      expect(await c.toggleMute(), 0);
      expect(await c.toggleMute(), 10,
          reason: '静音前音量字段独立，按进入静音那一刻的音量恢复，未被旧 80 污染');
      expect(c.volume, 10);
    });

    test(
        'setVolume during mute does not change the pre-mute restore value '
        '(TODO-433 bug1)', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);

      await c.setVolume(55);
      await c.toggleMute();
      expect(c.muted, isTrue);

      // 静音期间显式 setVolume(0) 不解除静音，也不该影响「静音前音量」恢复目标。
      await c.setVolume(0);
      expect(c.muted, isTrue, reason: 'setVolume(0) 不解除静音');

      // 取消静音仍恢复到进入静音那一刻的 55（静音前音量字段未被 setVolume(0) 污染）。
      expect(await c.toggleMute(), 55,
          reason: '静音前音量只在进入静音那一刻写一次，setVolume 不碰它');
      expect(c.muted, isFalse);
      expect(c.volume, 55);
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

  // BUG-179：安卓视频退出重进不从上次位置继续。
  //
  // 恢复 seek 守护 _restoreTargetMs：seek 落地前禁止三个写入点用过渡期小值（0/小值）
  // 覆盖真实进度。旧实现的守护**只**靠「position 追上目标」清除；seek 在慢设备 / 软解
  // （Android 尤甚）上若被 libmpv 丢弃、position 停在 0 附近从头播，守护**永久**不清 →
  // 这一程进度全被跳过（没回到上次位置，也没记住这次）。修复给守护加有界宽限：连续
  // _restoreGuardGraceTicks 次仍未追上目标即放弃守护，让写入恢复正常。
  group('VideoPlayerController BUG-179 恢复守护有界宽限', () {
    test('TODO-250: synthetic 初始位置只同步 cue，不写入也不清恢复守护', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      c.setCues(<AudioCue>[_cue(0, 49000, 51000)]);
      c.debugPrimeRestoreGuardForTesting(bookUid: 'v1', restoreTargetMs: 50000);

      c.debugSyncInitialCueForPosition(50000);

      expect(c.currentCueIndex, 0,
          reason: 'load 仍要用 initialPositionMs 初始化当前字幕');
      expect(writes, isEmpty,
          reason: 'synthetic initialPositionMs 不是真实 player position，不能落库');
      expect(c.debugRestoreGuardActive, isTrue,
          reason: 'synthetic initialPositionMs 不能被当成 seek 已追上目标');
    });

    test('TODO-250: synthetic 后真实低位 tick 仍被挡，追近目标才写入', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      c.setCues(<AudioCue>[_cue(0, 49000, 51000)]);
      c.debugPrimeRestoreGuardForTesting(bookUid: 'v1', restoreTargetMs: 50000);

      c.debugSyncInitialCueForPosition(50000);
      c.debugUpdateCueForPosition(0);
      c.debugUpdateCueForPosition(1000);

      expect(writes, isEmpty, reason: '真实播放器还停在 0/1000 时，不能覆盖已保存进度');
      expect(c.debugRestoreGuardActive, isTrue);

      c.debugUpdateCueForPosition(49000); // 进入 1.5s 容差，视为 seek 已落地。

      expect(c.debugRestoreGuardActive, isFalse);
      expect(writes, <int>[49000], reason: '只有真实 tick 追近/追上目标后，本次位置才允许落库');
    });

    test('正常恢复：position 追上目标后立即清守护、恢复写入', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      c.debugPrimeRestoreGuardForTesting(bookUid: 'v1', restoreTargetMs: 50000);

      // seek 落地前的过渡期小值：被守护跳过，不写。
      c.debugUpdateCueForPosition(0);
      c.debugUpdateCueForPosition(1000);
      expect(writes, isEmpty, reason: '恢复未落地，过渡期小值不得覆盖真实进度');
      expect(c.debugRestoreGuardActive, isTrue);

      // position 追上目标（容差 1.5s 内）：守护立即清，本次写入放行。
      c.debugUpdateCueForPosition(49000); // 50000-1500=48500，49000 已追上
      expect(c.debugRestoreGuardActive, isFalse);
      expect(writes, <int>[49000]);

      // 守护清除后照常持久化。
      c.debugUpdateCueForPosition(51000);
      expect(writes, <int>[49000, 51000]);
    });

    test('恢复失败兜底：宽限耗尽后放弃守护，从此正常记住进度', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      // 目标设很大（600000ms）：模拟用户上次看到很后面退出。seek 落地失败时 position
      // 从 0 起、在低位前进，整程都 < target-1500，永远追不上 → 测「宽限兜底」路径。
      c.debugPrimeRestoreGuardForTesting(
          bookUid: 'v1', restoreTargetMs: 600000);

      final int grace = VideoPlayerController.debugRestoreGuardGraceTicks;
      // 喂 grace-1 次「整秒互不相同、始终远低于目标」的位置：每次未追上 → 跳过写入 +
      // 消耗一格宽限。用 1000..(grace-1)*1000，最大 ~79000 仍远 < 598500。
      for (int i = 1; i < grace; i++) {
        c.debugUpdateCueForPosition(i * 1000);
      }
      expect(writes, isEmpty, reason: '宽限耗尽前，未追上目标一律跳过写入');
      expect(c.debugRestoreGuardActive, isTrue, reason: '宽限尚未耗尽，守护仍在');

      // 第 grace 次观测仍未追上 → 宽限耗尽，主动放弃守护（本次仍不写，下一拍起恢复）。
      c.debugUpdateCueForPosition(grace * 1000);
      expect(c.debugRestoreGuardActive, isFalse,
          reason: '宽限耗尽：判定 seek 落地失败，放弃守护');

      // 守护放弃后，用户从头看的进度被正常记住（BUG-179 修复核心）。
      c.debugUpdateCueForPosition((grace + 5) * 1000);
      expect(writes, contains((grace + 5) * 1000), reason: '守护放弃后，这一程的进度必须能记住');
    });

    test('回归：旧实现下该序列永远不写（守护永不清）—— 本测试钉住已修复', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
      c.debugPrimeRestoreGuardForTesting(
          bookUid: 'v1', restoreTargetMs: 600000);

      // 喂远超宽限上限次数、始终远低于目标的位置（旧实现：守护永久挡 → writes 恒空）。
      for (int i = 0;
          i < VideoPlayerController.debugRestoreGuardGraceTicks + 30;
          i++) {
        c.debugUpdateCueForPosition((i % 5) * 1000); // 在 0..4000 循环，永不接近 600000
      }
      expect(c.debugRestoreGuardActive, isFalse, reason: '守护必须已被宽限放弃');
      expect(writes, isNotEmpty, reason: '放弃守护后写入恢复，进度被记住（旧实现此处为空）');
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

  // BUG-176: 句子快进/后退在「句间静音 gap」里的目标索引决策。gap 时
  // updateCueForPosition 把 currentCueIndex 清成 -1（BUG-074），旧实现裸用
  // `_currentCueIndex ± 1`：下一句 = -1+1 = 0（恒跳首句起点 = 打回原点 / 进度条圆点
  // 闪开头）；上一句 = -1-1 = -2（恒越界 no-op = gap 里后退失灵）。新决策按真实
  // position 二分回退，永不返回负值/原点。
  group('BUG-176 句子跳转目标索引（gap 不打回原点）', () {
    final cues = <AudioCue>[
      _cue(0, 0, 1000),
      _cue(1, 2000, 3000),
      _cue(2, 4000, 5000),
    ];

    group('nextCueIndexFor', () {
      test('定位到当前 cue：取下一条', () {
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 500),
          1,
        );
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 2500),
          2,
        );
      });

      test('已在末句：返回 null（不动）', () {
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 4500),
          isNull,
        );
      });

      test('gap（idx=-1）里 cue0 与 cue1 之间：下一句 = cue1，不打回原点', () {
        // pos=1500 落在 cue0(0-1000) 与 cue1(2000-3000) 的 gap。旧实现会给 0。
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 1500),
          1,
        );
      });

      test('gap 在 cue1 与 cue2 之间：下一句 = cue2', () {
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 3500),
          2,
        );
      });

      test('早于首句（开头静音）：下一句 = 首句 0', () {
        // 这里跳 0 是对的（用户本就在 0 之前），但不是「从 gap 打回原点」。
        final lateStart = <AudioCue>[_cue(0, 1000, 2000), _cue(1, 3000, 4000)];
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: lateStart, positionMs: 200),
          0,
        );
      });

      test('gap 在末句之后：返回 null（已无下一句）', () {
        expect(
          VideoPlayerController.nextCueIndexFor(cues: cues, positionMs: 9000),
          isNull,
        );
      });

      test('空 cue 列表：null', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: const <AudioCue>[], positionMs: 0),
          isNull,
        );
      });
    });

    group('prevCueIndexFor', () {
      test('定位到当前 cue：取前一条', () {
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 4500),
          1,
        );
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 2500),
          0,
        );
      });

      test('已在首句：返回 null（不动）', () {
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 500),
          isNull,
        );
      });

      test('gap（idx=-1）在 cue1 与 cue2 之间：上一句 = cue1，不越界 no-op', () {
        // pos=3500 落在 cue1(2000-3000) 与 cue2(4000-5000) 的 gap。
        // 旧实现 -1-1=-2 恒 no-op；新决策回退到 gap 之前那条 = cue1。
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 3500),
          1,
        );
      });

      test('gap 在 cue0 与 cue1 之间：上一句 = cue0', () {
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 1500),
          0,
        );
      });

      test('早于首句：上一句落首句 0（不返回负值）', () {
        final lateStart = <AudioCue>[_cue(0, 1000, 2000), _cue(1, 3000, 4000)];
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: lateStart, positionMs: 200),
          0,
        );
      });

      test('gap 在末句之后：上一句 = 末句', () {
        expect(
          VideoPlayerController.prevCueIndexFor(cues: cues, positionMs: 9000),
          2,
        );
      });

      test('空 cue 列表：null', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: const <AudioCue>[], positionMs: 0),
          isNull,
        );
      });
    });

    // TODO-085：Ctrl+← 跳上一句时，若上一句起点距当前位置 > seekSeconds 秒，则退化
    // 成回退 seekSeconds 秒（不一脚跳到很远的上一句）。
    group('prevSeekDecisionFor (TODO-085 上句太远回退Xs)', () {
      // cue0 [0,1000]、cue1 [10000,11000]、cue2 [12000,13000]：cue0↔cue1 之间是
      // 一段很长的 gap，便于构造「上一句很远」。
      final farCues = <AudioCue>[
        _cue(0, 0, 1000),
        _cue(1, 10000, 11000),
        _cue(2, 12000, 13000),
      ];

      test('上一句很近（gap <= Xs）：跳到该 cue（句子 seek）', () {
        // 当前定位在 cue2(12000)，上一句 = cue1(10000)，距当前 ~2s <= 3s → 跳句。
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          positionMs: 12500,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.cue(1));
        expect(d.timeSeekDeltaMs, isNull);
      });

      test('上一句很远（gap > Xs）：退化成回退 Xs 秒（时间 seek）', () {
        // 当前定位在 cue1(10000)，上一句 = cue0(0)，距当前 10s > 3s → 不跳到 cue0，
        // 改回退 3s。
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          positionMs: 10000,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.timeSeek(-3000));
        expect(d.cueIndex, isNull);
      });

      test('gap 里（idx=-1）上一句很远：同样退化回退 Xs', () {
        // pos=8000 落在 cue0(0-1000) 与 cue1(10000-11000) 的长 gap，
        // 上一句 = cue0(0)，距当前 8s > 3s → 回退 3s。
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          positionMs: 8000,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.timeSeek(-3000));
      });

      test('阈值边界：恰好等于 Xs 仍跳句（> 才退化）', () {
        // 上一句 = cue0(0)，pos=3000 → gap = 3000 == 3*1000，不 > 阈值 → 跳句。
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: <AudioCue>[_cue(0, 0, 1000), _cue(1, 5000, 6000)],
          positionMs: 3000,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.cue(0));
      });

      test('已在首句：none（不强行回退到负位置）', () {
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          positionMs: 500,
          seekSeconds: 3,
        );
        expect(d, PrevSeekDecision.none);
        expect(d.cueIndex, isNull);
        expect(d.timeSeekDeltaMs, isNull);
      });

      test('空 cue 列表：none', () {
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: const <AudioCue>[],
          positionMs: 0,
          seekSeconds: 3,
        );
        expect(d, PrevSeekDecision.none);
      });

      test('seekSeconds<=0 防御：阈值失效，恒跳句', () {
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          positionMs: 10000,
          seekSeconds: 0,
        );
        expect(d, const PrevSeekDecision.cue(0));
      });

      test('PrevSeekDecision 值相等性', () {
        expect(const PrevSeekDecision.cue(2), const PrevSeekDecision.cue(2));
        expect(const PrevSeekDecision.cue(2) == const PrevSeekDecision.cue(3),
            isFalse);
        expect(const PrevSeekDecision.timeSeek(-3000),
            const PrevSeekDecision.timeSeek(-3000));
        expect(PrevSeekDecision.none == const PrevSeekDecision.cue(0), isFalse);
      });
    });

    test('回归：先进句到 cue0、再 update 到 gap 清成 -1，next 不应回 0', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(cues);
      c.debugUpdateCueForPosition(500); // 定位 cue0
      expect(c.currentCueIndex, 0);
      c.debugUpdateCueForPosition(1500); // 进入 gap → -1（BUG-074）
      expect(c.currentCueIndex, -1);
      // 此刻按「下一句」：决策必须按 position(1500) 回退到 cue0 再 +1 = cue1，
      // 绝不能因 -1+1 跳回 cue0（原点）。
      expect(
        VideoPlayerController.nextCueIndexFor(cues: c.cues, positionMs: 1500),
        1,
      );
    });

    // TODO-410 / BUG-302：视频「下一句」跳到当前句。
    //
    // 根因：125ms tick 更新的 [_currentCueIndex] 有滞后窗口——用户 seek 进某句后 tick
    // 尚未追平时，旧实现裸信 [_currentCueIndex]（仍停在上一句）→ next = 上一句+1 = 当前
    // 句本身（「下一句跳到当前句」），prev = 上一句-1（乱跳 / no-op）。修复：next/prev 一
    // 律按实时 [positionMs] 定位当前句，严格排除当前句。
    //
    // 构造：相邻无 gap 的两条 cue，实时位置 14000 落在 cue1 内，但成员变量
    // [_currentCueIndex] 仍是陈旧的 0（停在 cue0）。撤掉修复（回到读 currentCueIndex）
    // 时本用例会红：next 会算成 0+1=1（=当前句 cue1，错），prev 会算成 0-1=null（不动，错）。
    group('TODO-410 stale currentCueIndex：next/prev 按实时 position 排除当前句', () {
      // 相邻无 gap：cue1 紧接 cue0 之后；14000 落在 cue1 时间窗内。
      final adjacent = <AudioCue>[
        _cue(0, 0, 14000),
        _cue(1, 14000, 28000),
        _cue(2, 28000, 42000),
      ];

      test('position 在 cue1 内、currentCueIndex 陈旧停在 0：下一句 = cue2（不是 cue1）', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: adjacent, positionMs: 14000),
          2,
          reason: '实时 position=14000 已在 cue1 内，下一句应是 cue2；旧实现裸信 stale '
              'currentCueIndex=0 会算成 cue1（=当前句本身）',
        );
      });

      test('position 在 cue1 内、currentCueIndex 陈旧停在 0：上一句 = cue0（不乱跳/不 no-op）',
          () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: adjacent, positionMs: 14000),
          0,
          reason: '实时 position=14000 已在 cue1 内，上一句应是 cue0；旧实现裸信 stale '
              'currentCueIndex=0 会算成 0-1=null（不动）',
        );
      });

      test('真实控制器：tick 滞后（currentCueIndex=0）下 next/prev 仍按 position 决策', () {
        final c = VideoPlayerController();
        addTearDown(c.dispose);
        c.setCues(adjacent);
        // 先把 tick 同步到 cue0（模拟刚播 cue0 时 tick 写入 currentCueIndex=0）。
        c.debugUpdateCueForPosition(5000);
        expect(c.currentCueIndex, 0, reason: 'tick 把当前句记成 cue0');
        // 用户 seek 进 cue1（live position=14000），但 tick 尚未跑、currentCueIndex 仍是 0。
        expect(c.currentCueIndex, 0, reason: 'tick 滞后：成员变量仍停在 cue0');
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: c.cues, positionMs: 14000),
          2,
          reason: '下一句必须按实时 position(14000=cue1) 排除当前句 → cue2',
        );
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: c.cues, positionMs: 14000),
          0,
          reason: '上一句必须按实时 position(14000=cue1) → cue0',
        );
      });
    });
  });

  // TODO-571 / BUG-329：视频「上一句/下一句」字幕跳转跳过头（上一句跳到 N-2）/ 原地
  // 不动（下一句卡在刚跳到的那句）。
  //
  // 根因：skipToCue 的 seek 落点因前导余量 kCueSeekPreRollMs(=180) **故意**偏到目标句
  // startMs 之前（cueSeekTargetMs，吸收 media_kit 关键帧吸附 BUG-259 / 听感）。连续按
  // 跳句时，第二次读到的实时 position 正是这个偏前落点：
  //   - 上一句：偏前落点退进「目标句的上一句」时间窗，findCueIndex 命中上一句 → hit-1
  //     跳到上上句 → 跳过头（N-2，正是用户报「感觉跳过头了」）。
  //   - 下一句：偏前落点还没到目标句 startMs，_floorCueIndexByPosition 据 startMs<=pos
  //     反推当前句成目标句的上一句 → +1 又指回刚跳到的目标句 → 原地不动。
  //
  // 修复：nextCueIndexFor / prevCueIndexFor / prevSeekDecisionFor 接受 anchorIndex
  // （= 上次主动跳转目标 _seekTargetCueIndex，565 已在 preRoll 引导窗口内维护其生命周期）。
  // 锚存活时严格 anchor±1，绕过按偏前 position 反推 floor/命中。
  group('TODO-571 锚定上次主动跳转目标：连续跳句不跳过头 / 不原地', () {
    // cue 间有小 gap（真实 SRT/ASS 字幕常见），startMs 间隔 1000ms，preRoll=180。
    final spaced = <AudioCue>[
      _cue(0, 1000, 1900),
      _cue(1, 2000, 2900),
      _cue(2, 3000, 3900),
      _cue(3, 4000, 4900),
    ];

    test('下一句：anchor=1 时严格取 cue2，不被偏前落点拖回 cue1（原地）', () {
      // 模拟刚跳到 cue1：seek 落点 = 2000-180 = 1820（< cue1.startMs，落 cue0 时间窗）。
      // 不带 anchor：floor(1820 by startMs)=0 → next=1（=刚跳到的 cue1，原地不动，错）。
      expect(
        VideoPlayerController.nextCueIndexFor(cues: spaced, positionMs: 1820),
        1,
        reason: '无 anchor 时偏前落点把当前句反推成 cue0，下一句又指回 cue1（原地）',
      );
      // 带 anchor=1（_seekTargetCueIndex）：严格 anchor+1 = cue2（真前进）。
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 1820, anchorIndex: 1),
        2,
        reason: '锚定刚跳到的 cue1，下一句必须是 cue2，不受 preRoll 偏前落点干扰',
      );
    });

    test('上一句：anchor=2 时严格取 cue1，不跳过头到 cue0（N-2）', () {
      // 模拟刚跳到 cue2：seek 落点 = 3000-180 = 2820（落 cue1[2000,2900] 时间窗内）。
      // 不带 anchor：findCueIndex(2820)=cue1 → prev=0（cue0，跳过 cue1，跳过头，错）。
      expect(
        VideoPlayerController.prevCueIndexFor(cues: spaced, positionMs: 2820),
        0,
        reason: '无 anchor 时偏前落点退进 cue1 时间窗，上一句跳到 cue0（跳过头 N-2）',
      );
      // 带 anchor=2（_seekTargetCueIndex）：严格 anchor-1 = cue1（相邻 N-1）。
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 2820, anchorIndex: 2),
        1,
        reason: '锚定刚跳到的 cue2，上一句必须是相邻的 cue1，绝不跳过头到 cue0',
      );
    });

    test('连续下一句逐句前进：anchor 链 1→2→3', () {
      // 模拟链：每次跳完 _seekTargetCueIndex = 上次目标，position 落偏前落点。
      // anchor=1, pos=1820（cue2 偏前前一步的落点不影响，anchor 主导）→ next=2
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 1820, anchorIndex: 1),
        2,
      );
      // anchor=2, pos=2820 → next=3
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 2820, anchorIndex: 2),
        3,
      );
      // anchor=3（末句）, pos=3820 → null（无下一句，no-op）
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 3820, anchorIndex: 3),
        isNull,
        reason: 'anchor 已是末句：下一句越界返回 null（保持末句 no-op 边界）',
      );
    });

    test('连续上一句逐句后退：anchor 链 2→1→0→null', () {
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 2820, anchorIndex: 2),
        1,
      );
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 1820, anchorIndex: 1),
        0,
      );
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 820, anchorIndex: 0),
        isNull,
        reason: 'anchor 已是首句：上一句越界返回 null（保持首句 no-op 边界）',
      );
    });

    test('anchor 越界（脏快照）时退回纯位置推导，不崩', () {
      // anchorIndex 超出范围 → 走原 position 逻辑（防御：快照与 cues 不同步时不应锚错）。
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 1500, anchorIndex: 99),
        1,
        reason: '越界 anchor 忽略，按 position(1500=cue0 后 gap) floor 取下一句 cue1',
      );
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 3500, anchorIndex: -5),
        1,
        reason: '负 anchor 忽略，按 position(3500=cue1 后 gap) 回退到 cue1',
      );
    });

    test('anchorIndex==null（首次从自然播放跳）时行为不变（向后兼容）', () {
      // 无快照：与现有 TODO-410 行为完全一致（按 position 反推）。
      expect(
        VideoPlayerController.nextCueIndexFor(
            cues: spaced, positionMs: 2500, anchorIndex: null),
        VideoPlayerController.nextCueIndexFor(cues: spaced, positionMs: 2500),
      );
      expect(
        VideoPlayerController.prevCueIndexFor(
            cues: spaced, positionMs: 2500, anchorIndex: null),
        VideoPlayerController.prevCueIndexFor(cues: spaced, positionMs: 2500),
      );
    });

    test('prevSeekDecisionFor 锚定：anchor=2 取相邻 cue1（不跳过头），距离仍按真实 position', () {
      // pos=2820（偏前落点）, anchor=2, seekSeconds=3。相邻上一句 cue1.startMs=2000，
      // gap = 2820-2000 = 820ms <= 3000ms → 跳句到 cue1（不退化、不跳过头）。
      final d = VideoPlayerController.prevSeekDecisionFor(
        cues: spaced,
        positionMs: 2820,
        seekSeconds: 3,
        anchorIndex: 2,
      );
      expect(d, const PrevSeekDecision.cue(1),
          reason: '锚定 cue2 → 上一句 cue1（相邻），距离 820ms 未超阈值，跳句不退化');
    });
  });

  // TODO-073: 视频 OP（片头）段没有字幕时，按「下一句字幕」按钮跳回开头。
  //
  // 用户复现：OP 歌词没有字幕（首条 cue 在 OP 之后，如真实龙女仆 S01E01 首条 cue
  // 在 38456ms）。在 OP 里按下一句：
  //   - 有字幕但 position 早于首句：nextCueIndexFor 返回 0 → 跳到首句 startMs（前进，
  //     绝不回开头/0）。这是 BUG-176 已修的正确行为，这里用真实 OP cue 结构钉死防回归。
  //   - 无字幕（空 cue 列表）：旧的按钮直接 skipToNextCue() → no-op（按钮毫无反应，用户
  //     感知「卡住 / 没动」）。新增 skipToNextCueOrSeekForward 让无字幕时前进 seekSeconds
  //     秒（与 skipToPrevCueOrSeekBack 对称），跨过没字幕的 OP。
  group('TODO-073 OP 无字幕「下一句」不回开头', () {
    // 真实结构：首条 cue 在 OP 之后（38456ms）。OP 段 0..38456 无 cue。
    final opCues = <AudioCue>[
      _cue(0, 38456, 42000),
      _cue(1, 45212, 48000),
      _cue(2, 48758, 52000),
    ];

    test('OP 里（position 早于首句）下一句 = 首句索引 0（跳到 38456ms = 前进，不回 0）', () {
      for (final int pos in <int>[0, 1000, 10000, 20000, 38000]) {
        expect(
          VideoPlayerController.nextCueIndexFor(cues: opCues, positionMs: pos),
          0,
          reason:
              'OP position=$pos 早于首句：下一句应是首句(0)，seek 到 ${opCues[0].startMs}ms '
              '前进，绝不返回越界/负值导致回开头',
        );
      }
    });

    test('回归：tick 把 OP position 同步成 currentCueIndex=-1 后，下一句仍前进到首句', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(opCues);
      c.debugUpdateCueForPosition(10000); // OP 内：早于首句 38456 → -1
      expect(c.currentCueIndex, -1, reason: 'OP 段无 cue 覆盖，当前索引应为 -1');
      expect(
        VideoPlayerController.nextCueIndexFor(cues: c.cues, positionMs: 10000),
        0,
        reason: '从 OP gap 按下一句必须前进到首句(0=38456ms)，不能回开头',
      );
    });

    test('已在末句之后（片尾无字幕）下一句 = null（保持原位，不回开头也不越界）', () {
      expect(
        VideoPlayerController.nextCueIndexFor(cues: opCues, positionMs: 200000),
        isNull,
      );
    });

    test('skipToNextCueOrSeekForward：空 cue 列表不抛、安全 no-op（无 player 时）',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 无字幕 + 无 player：empty 分支走 seekRelative，positionMs==null → no-op 安全。
      await c.skipToNextCueOrSeekForward(seekSeconds: 5);
      expect(c.cues, isEmpty);
      expect(c.positionMs, isNull, reason: '无 player：seekRelative 不动（不会回到 0）');
    });

    test('skipToNextCueOrSeekForward：有 cue 时走 cue 决策（无 player 时安全 no-op）',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(opCues);
      c.debugUpdateCueForPosition(10000);
      // 无 player：skipToCue→seekMs 是 no-op，但不应抛、不应改 cue 状态指向原点。
      await c.skipToNextCueOrSeekForward(seekSeconds: 5);
      expect(c.currentCueIndex, -1,
          reason: 'seek 是 no-op（无 player），cue 状态不被错误改写');
    });
  });

  // TODO-119: 视频转场/无字幕段，按「上一句字幕」按钮 / 键盘没反应、回退不了。
  //
  // 这是 TODO-073「下一句」方向的反方向。用户复现：动画转场片段没配音和字幕（落在两条
  // cue 之间的长 gap，或整段无字幕轨）时，按「字幕回退键」毫无反应：
  //   - 有字幕但上一句太远（转场 gap）：旧的底栏「上一句」按钮走裸 skipToPrevCue →
  //     prevCueIndexFor 会一脚跳到很远的上一句，或在已是首句时 no-op；而键盘已经走
  //     skipToPrevCueOrSeekBack 退化回退 Xs（TODO-085）。本组钉死按钮也走同一退化决策。
  //   - 无字幕（空 cue 列表）：旧的 skipToPrevCue() 直接 no-op（按钮毫无反应，用户感知
  //     「卡住 / 回退不了」）。skipToPrevCueOrSeekBack 让无字幕时回退 seekSeconds 秒
  //     （与 skipToNextCueOrSeekForward 前进 Xs 对称），跨过没字幕的转场段往回走。
  //   - 开头边界：回退不能越过 0（clampSeekTargetMs 下界 clamp）。
  group('TODO-119 转场/无字幕「上一句」不卡住（对称 TODO-073）', () {
    // 真实结构：cue0 在转场之后（38456ms），cue0 与 cue1 之间又有一段长转场 gap。
    final transitionCues = <AudioCue>[
      _cue(0, 38456, 42000),
      _cue(1, 90000, 93000),
      _cue(2, 93500, 96000),
    ];

    test('转场 gap 里上一句很远：退化成回退 Xs（时间 seek，不一脚跳到很远的上一句）', () {
      // pos=70000 落在 cue0(38456-42000) 与 cue1(90000-93000) 的长转场 gap：
      // 上一句 = cue0(38456)，距当前 ~31.5s > 3s → 回退 3s（绝不跳回 38456 那么远）。
      final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
        cues: transitionCues,
        positionMs: 70000,
        seekSeconds: 3,
      );
      expect(d, const PrevSeekDecision.timeSeek(-3000),
          reason: '转场 gap 上一句太远 → 回退 seekSeconds 秒，不卡住也不跳到很远的上句');
    });

    test('转场 gap 里上一句很近：跳到该 cue（句子 seek，原有行为不退化）', () {
      // pos=43000 落在 cue0(38456-42000) 之后的小 gap：上一句 = cue0(38456)，
      // 距当前 ~4.5s。用更大的 seekSeconds=10s 阈值 → 4.5s <= 10s → 跳句。
      final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
        cues: transitionCues,
        positionMs: 43000,
        seekSeconds: 10,
      );
      expect(d, const PrevSeekDecision.cue(0),
          reason: '上一句够近（<= seekSeconds）时仍跳到该 cue，不退化成时间 seek');
    });

    test('开头边界：回退目标 clamp 到 0（不越过视频开头到负位置）', () {
      // 位置 1200ms，回退 3000ms → 原始目标 -1800 → clamp 到 0（开头）。
      expect(
        VideoPlayerController.clampSeekTargetMs(1200, -3000, 600000),
        0,
        reason: '转场段靠近开头按回退键：目标越界为负 → clamp 到 0，停在视频开头',
      );
      // 已在 0：再回退仍是 0（不抖到负）。
      expect(VideoPlayerController.clampSeekTargetMs(0, -3000, 600000), 0);
      // 正常段回退：不 clamp。
      expect(
          VideoPlayerController.clampSeekTargetMs(50000, -3000, 600000), 47000);
    });

    test('skipToPrevCueOrSeekBack：空 cue 列表不抛、安全 no-op（无 player 时）', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 无字幕 + 无 player：empty 分支走 seekRelative，positionMs==null → no-op 安全。
      await c.skipToPrevCueOrSeekBack(seekSeconds: 5);
      expect(c.cues, isEmpty);
      expect(c.positionMs, isNull, reason: '无 player：seekRelative 不动（不会乱跳）');
    });

    test('skipToPrevCueOrSeekBack：有 cue 时走 prev 决策（无 player 时安全 no-op）',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(transitionCues);
      c.debugUpdateCueForPosition(70000); // 转场 gap → -1
      expect(c.currentCueIndex, -1);
      // 无 player：seek 是 no-op，但不应抛、不应把 cue 状态错误改写。
      await c.skipToPrevCueOrSeekBack(seekSeconds: 3);
      expect(c.currentCueIndex, -1,
          reason: 'seek 是 no-op（无 player），cue 状态不被错误改写');
    });
  });

  group('BUG-301 图形字幕调轴 → libmpv sub-delay 分流', () {
    test('文本模式（默认 / setCues 非空）：sub-delay 恒 0，不随 setDelayMs 变', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 默认即文本/无字幕模式：图形标志 false。
      expect(c.debugGraphicSubtitleActive, isFalse);
      c.setCues([_cue(0, 0, 1000)]); // 非空文本 cue
      expect(c.debugGraphicSubtitleActive, isFalse);
      // 文本字幕偏移在 Dart 侧扣减（effectiveSubtitlePositionMs），mpv sub-delay 恒 0。
      c.setDelayMs(1500);
      expect(c.delayMs, 1500);
      expect(c.debugSubtitleDelayMpvMs, 0,
          reason: '文本模式不把延迟下发给 libmpv（避免双重偏移）');
    });

    test('图形模式：sub-delay = _delayMs / 1000（同向，不翻符号）', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 模拟 selectEmbeddedGraphicTrack 成功（宿主无 libmpv，真选轨返 false）。
      c.debugSetGraphicSubtitleActiveForTesting(true);
      c.setDelayMs(2000);
      expect(c.debugSubtitleDelayMpvMs, 2000,
          reason: '图形字幕走 libmpv 画面渲染：延迟必须下发到 sub-delay');
      // 纯函数把毫秒转秒、同向：2000ms → "2.0"。
      expect(buildSubtitleDelayProperty(c.debugSubtitleDelayMpvMs)['sub-delay'],
          '2.0');
      c.setDelayMs(-3000);
      expect(c.debugSubtitleDelayMpvMs, -3000);
      expect(buildSubtitleDelayProperty(c.debugSubtitleDelayMpvMs)['sub-delay'],
          '-3.0');
    });

    test('图形 → 文本切换：setCues(非空) 复位图形标志 → sub-delay 回 0', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetGraphicSubtitleActiveForTesting(true);
      c.setDelayMs(1500);
      expect(c.debugSubtitleDelayMpvMs, 1500);
      // 切到文本字幕源：非空 cue 复位图形标志，sub-delay 复位 0（防图形轨残留偏移）。
      c.setCues([_cue(0, 0, 1000)]);
      expect(c.debugGraphicSubtitleActive, isFalse);
      expect(c.debugSubtitleDelayMpvMs, 0);
    });

    test('图形 → 关字幕：selectSubtitleTrack(no()) 复位图形标志 → sub-delay 回 0', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetGraphicSubtitleActiveForTesting(true);
      c.setDelayMs(1000);
      expect(c.debugSubtitleDelayMpvMs, 1000);
      // 关字幕 / 切文本 overlay 都经 no()；无 player 时 setSubtitleTrack no-op，但标志复位。
      await c.selectSubtitleTrack(SubtitleTrack.no());
      expect(c.debugGraphicSubtitleActive, isFalse);
      expect(c.debugSubtitleDelayMpvMs, 0);
    });

    test('setCues(空) 不复位图形标志（图形轨场景：先清空 cue 再选轨）', () {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetGraphicSubtitleActiveForTesting(true);
      // selectEmbeddedGraphicTrack 内部先 setCues(空) 再选轨置 true；空 cue 不应误复位。
      c.setCues(const <AudioCue>[]);
      expect(c.debugGraphicSubtitleActive, isTrue,
          reason: '空 cue 不推断模式（图形轨与无字幕段都空，会误判）');
    });
  });

  // TODO-565：点字幕列表第 N 行，高亮却落在第 N-1 句（off-by-one 回归）。
  //
  // 根因：BUG-259 的前导余量（kCueSeekPreRollMs=180）让 skipToCue 的 seek 落点偏到目标句
  // 之前（cue.startMs - 180）。高亮真相源是「实时 position 经 findCueIndex 反推」，seek 刚
  // 落地、position 还在 [startMs-preRoll, startMs) 引导窗口时，findCueIndex 据实际位置正确
  // 地报上一句/ gap → 高亮先闪 N-1。修复：skipToCue 记录目标下标，_syncCueForPosition 在
  // 引导窗口内把命中下标 snap 回目标句；自然进入后清快照退回纯推导。
  group('TODO-565 字幕列表点击高亮不 off-by-one', () {
    test('纯函数 cueSnapIndex：preRoll 引导窗口内 snap 回目标句、保留快照', () {
      // 目标句 [startMs=2000, endMs=3000]、preRoll=180：snap 窗口 [1820, 3000]。落点 1850
      // 此刻 findCueIndex 命中上一句 0，应 snap 到目标 1 并保留快照（keep=true）。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 0,
          effectiveMs: 1850,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (1, true),
      );
      // gap 命中 -1 同样 snap 回目标。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: -1,
          effectiveMs: 1900,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (1, true),
      );
    });

    test('纯函数 cueSnapIndex：落点在目标句区间内（含吸附越句首）→ snap 回目标、保留快照（BUG-378）', () {
      // BUG-378 核心：position 已 >= startMs 但 <= endMs（落在目标句内）。旧判据
      // `eff >= startMs` 会清快照并用原命中下标；新判据收紧到 endMs，落在句内一律
      // snap 回目标句、保留快照——这样目标句很短、关键帧吸附把落点推进句内时不丢目标。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 1,
          effectiveMs: 2000, // 恰在 startMs
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (1, true),
      );
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 1,
          effectiveMs: 2500, // 句中
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (1, true),
      );
      // endMs 边界（闭区间）仍属目标句内 → snap 回目标。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 1,
          effectiveMs: 3000,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (1, true),
      );
    });

    test('纯函数 cueSnapIndex：自然越过目标句尾后用原命中下标、清快照', () {
      // position 已 > 目标 endMs：findCueIndex 命中下一句/gap，用原值、清快照（keep=false）。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 2,
          effectiveMs: 3001, // 刚越过 endMs=3000
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (2, false),
      );
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 2,
          effectiveMs: 5000,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 180,
        ),
        (2, false),
      );
    });

    test('纯函数 cueSnapIndex：短目标句吸附落点越过其 endMs 进下一句 → 仍 snap 回目标（BUG-378 真因）',
        () {
      // 极短目标句 cue1=[1050,1100]（仅 50ms），preRoll=180：snap 窗口 [870, 1100]。
      // 关键帧吸附把落点推到 1080（在 [1050,1100] 句内）→ findCueIndex 此刻可能因吸附
      // 命中下一句的边界，但 1080<=endMs(1100)，应 snap 回目标 1（不取 findCueIndex 的 2）。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 2, // 反推命中下一句（吸附边界 / gap 模糊）
          effectiveMs: 1080,
          targetIndex: 1,
          targetStartMs: 1050,
          targetEndMs: 1100,
          preRollMs: 180,
        ),
        (1, true),
        reason: '落点仍在短目标句区间内，必须 snap 回目标句而非多跳到下一句',
      );
      // 落点 1099（endMs 内最后 1ms）仍 snap 回目标。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 2,
          effectiveMs: 1099,
          targetIndex: 1,
          targetStartMs: 1050,
          targetEndMs: 1100,
          preRollMs: 180,
        ),
        (1, true),
      );
      // 真正越过 endMs（1101）才认定落定、用原命中、清快照。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 2,
          effectiveMs: 1101,
          targetIndex: 1,
          targetStartMs: 1050,
          targetEndMs: 1100,
          preRollMs: 180,
        ),
        (2, false),
      );
    });

    test('纯函数 cueSnapIndex：远早于引导窗口（被别的 seek 拉走）→ 用原命中、清快照', () {
      // 869 < 1050-180=870：在 snap 窗口之外（更早），跳转已失效，不 snap、清快照。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 0,
          effectiveMs: 869,
          targetIndex: 1,
          targetStartMs: 1050,
          targetEndMs: 1100,
          preRollMs: 180,
        ),
        (0, false),
      );
    });

    test('纯函数 cueSnapIndex：负 preRoll 当 0（preRoll 窗口退化，仍 snap 句区间内）', () {
      // preRoll<=0 时下界退化为 startMs：effective<startMs（句首之前）落「远早于窗口」清快照，
      // 但 startMs<=effective<=endMs（句内）仍 snap 回目标（endMs 判据不受 preRoll 影响）。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 0,
          effectiveMs: 1999, // < startMs=2000，preRoll=0 窗口空 → 清快照
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 0,
        ),
        (0, false),
      );
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 0,
          effectiveMs: 1999,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: -50,
        ),
        (0, false),
      );
      // 句内（2500）即使 preRoll=0 仍 snap 回目标。
      expect(
        VideoPlayerController.cueSnapIndex(
          findCueIndex: 1,
          effectiveMs: 2500,
          targetIndex: 1,
          targetStartMs: 2000,
          targetEndMs: 3000,
          preRollMs: 0,
        ),
        (1, true),
      );
    });

    // 回环守卫（最强）：复刻真实链路——点第 N 行 → skipToCue → seek 落点=startMs-preRoll
    // → tick 用该落点 updateCueForPosition → 断言高亮 = N，不是 N-1。
    // 撤掉 _syncCueForPosition 里的 snap 接入（idx = _applySeekTargetSnap(...)）即转红。
    test('点第 N 行 skipToCue 后，preRoll 落点处高亮目标句 N（非上一句 N-1）', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 密集对话：句间隔 < preRoll，落点会粘进上一句区间 → 旧实现高亮 N-1。
      c.setCues([
        _cue(0, 0, 1900),
        _cue(1, 2000, 3000),
        _cue(2, 3100, 4000),
      ]);

      // 点第 2 行（index 1）。skipToCue 记录目标下标（无 player 时 seek no-op，但快照已设）。
      await c.skipToCue(c.cues[1]);

      // tick 喂 preRoll 落点 = 2000-180 = 1820（落在 cue0 区间 [0,1900]，旧实现判 0）。
      c.debugUpdateCueForPosition(1820);
      expect(c.currentCueIndex, 1, reason: 'preRoll 引导窗口内应 snap 回点击的目标句');
      expect(c.currentCue!.text, 'line1');

      // 播放自然进入目标句区间：仍是目标句，快照已清，纯推导接管。
      c.debugUpdateCueForPosition(2100);
      expect(c.currentCueIndex, 1);

      // 继续自然播放到下一句：不再被旧目标粘住，正常前进。
      c.debugUpdateCueForPosition(3200);
      expect(c.currentCueIndex, 2, reason: '快照已清，自动跟随不被旧目标污染');
    });

    test('skipToCue 后用户主动 seekRelative 拉到别处：快照作废，按真实位置推导（不误 snap）', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([
        _cue(0, 0, 1000),
        _cue(1, 5000, 6000),
      ]);
      await c.skipToCue(c.cues[1]); // 目标=1，窗口 [4820,5000)，置在途 seek 宽限
      // 用户主动 seekRelative（与 skipToCue 不同路径）作废宽限+清快照；下个 tick 读到
      // 首句区间应高亮 0，绝不被旧目标 1 误 snap（手动 seek 仍能清快照）。
      await c
          .seekRelative(-100000); // 无 player 时 seek no-op，但 seekRelative 已清宽限
      c.debugUpdateCueForPosition(500);
      expect(c.currentCueIndex, 0, reason: '主动 seekRelative 已作废快照，按真实位置高亮');
    });

    // TODO-565 复核退回的真机时序漏洞：skipToCue 异步 seek 后，125ms tick 在 seek 落地
    // 前先读到 seek 之前的旧 position（media_kit position 不随 seek 同步更新，
    // video_player_controller.dart:208-214/1481-1484）。旧实现里这个 stale tick 落在
    // 「远早于引导窗口」情形 → cueSnapIndex 返回 keep=false → 清掉 _seekTargetCueIndex
    // 快照；等真落点 startMs-preRoll 的 tick 到来时快照已没了 → findCueIndex 反推 N-1 →
    // off-by-one 真机复发。修复：skipToCue 置「在途 seek 宽限」，position 首次进入引导
    // 窗口之前的若干 tick 内不因「远离窗口」清快照（撑到 seek 落地）。
    // 撤掉宽限保护（_applySeekTargetSnap 里的 _seekSnapGraceTicksLeft 分支）此测试转红：
    // stale tick 清了快照 → 落点 tick 反推 cue0（N-1）。
    test('在途 seek 的 stale tick（旧远位置）先到：不清快照，真落点仍高亮目标句 N', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 密集对话：句间隔 < preRoll，落点会粘进上一句区间 → 无快照时高亮 N-1。
      c.setCues([
        _cue(0, 0, 1900),
        _cue(1, 2000, 3000),
        _cue(2, 3100, 4000),
      ]);

      // 点第 2 行（index 1，startMs=2000）。skipToCue 记录目标 + 置在途 seek 宽限
      // （无 player 时 seek no-op，但快照与宽限已设）。
      await c.skipToCue(c.cues[1]);

      // ① stale tick：seek 尚未落地，tick 先读到 seek 之前的旧远位置 300
      //    （300 < 2000-180=1820，落「远早于引导窗口」情形）。旧实现在此清快照。
      c.debugUpdateCueForPosition(300);
      expect(c.debugSeekTargetCueIndex, 1,
          reason: '在途 seek 的 stale tick 不得清快照（宽限保护，撑到落点）');

      // ② 真落点 tick：seek 落地，position 进入引导窗口 1820（落 cue0 区间 [0,1900]）。
      //    快照仍在 → snap 回目标句 1，而不是按真实位置反推的 cue0（N-1）。
      c.debugUpdateCueForPosition(1820);
      expect(c.currentCueIndex, 1,
          reason: 'stale tick 后快照仍在，真落点处 snap 回目标句 N（非上一句 N-1）');
      expect(c.currentCue!.text, 'line1');

      // ③ 播放自然进入目标句：宽限已作废、快照已清，纯位置推导接管。
      c.debugUpdateCueForPosition(2100);
      expect(c.currentCueIndex, 1);
      c.debugUpdateCueForPosition(3200);
      expect(c.currentCueIndex, 2, reason: '快照已清，自动跟随不被旧目标污染');
    });

    // 在途 seek 永不落地（慢设备 / libmpv 丢弃，对齐 BUG-179）：宽限有界，耗尽后放弃
    // 保护、退回纯位置推导，绝不因永久保护把高亮永久钉在旧目标上。
    test('在途 seek 宽限有界：连续 stale tick 耗尽配额后退回纯位置推导', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([
        _cue(0, 0, 1000),
        _cue(1, 5000, 6000),
      ]);
      await c.skipToCue(c.cues[1]); // 目标=1，窗口 [4820,5000)
      // 喂「宽限格数 + 余量」次 stale tick（都在首句区间、远早于窗口）：耗尽宽限。
      final int grace = VideoPlayerController.debugSeekSnapGraceTicks;
      for (int i = 0; i <= grace; i++) {
        c.debugUpdateCueForPosition(500);
      }
      expect(c.debugSeekTargetCueIndex, isNull,
          reason: '宽限耗尽：放弃保护、清快照（seek 落地失败兜底）');
      expect(c.currentCueIndex, 0, reason: '退回纯位置推导，高亮真实位置 cue0');
    });

    // TODO-565 复核退回的必修项：点字幕行 N（skipToCue 置目标 N + 在途 seek 宽限）后，
    // 落地前用户经收藏句 / 章节跳转 / 相对 seek（都汇到 seekMs）跳到更早句 M（M<N）。
    // 这些入口绕开 skipToCue 但经 seekMs；旧实现 seekMs 不清快照 → 下个 tick 读到 M
    // （远早于 N 的引导窗口、宽限未耗尽）→ _applySeekTargetSnap 情形 2 误 snap 回 N，
    // 高亮被钉在旧目标行 N 约 2 秒。修复：seekMs 开头统一清「主动跳转目标」快照。
    // 撤掉 seekMs 里的 _clearSeekTargetSnap() 此测试转红：tick 喂 M 时仍被误 snap 回 N。
    test('skipToCue 宽限未耗尽时经 seekMs 跳更早句：快照被清，高亮真实位置 M（不误 snap 回 N）', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 句间隔 > preRoll，让各句区间清晰；M=300 落 cue0、目标 N=2 起点 5000。
      c.setCues([
        _cue(0, 0, 1000),
        _cue(1, 3000, 4000),
        _cue(2, 5000, 6000),
      ]);

      // 点第 3 行（index 2，startMs=5000）：skipToCue 置目标 2 + 满宽限（无 player 时
      // seek no-op，但快照与宽限已设）。
      await c.skipToCue(c.cues[2]);
      expect(c.debugSeekTargetCueIndex, 2,
          reason: 'skipToCue 后快照应指向点击的目标句 N（顺序调整不破坏自身快照）');

      // 落地前用户经 seekMs 跳到更早位置 M=300（模拟收藏句 / 章节 / 相对 seek 入口）。
      // 宽限此刻仍满（未消耗），M=300 远早于目标 N 的引导窗口 [4820,5000)。
      await c.seekMs(300);
      expect(c.debugSeekTargetCueIndex, isNull,
          reason: 'seekMs 统一清除点：手动跳更早句必须作废旧主动跳转快照');

      // 下个 tick 读到 M：纯位置推导高亮 cue0，绝不被旧目标 2 误 snap。
      c.debugUpdateCueForPosition(300);
      expect(c.currentCueIndex, 0,
          reason: '快照已清，按真实位置 M 高亮 cue0（非误 snap 回旧目标 N=2）');
    });

    // 守卫 skipToCue 的顺序调整（先 seekMs 发 seek，再置快照+宽限）没把自己的快照清掉：
    // seekMs 是统一清除点，若 skipToCue 仍「先置快照再 seekMs」会被自清成 off-by-one。
    // 撤掉顺序调整（把置快照搬回 seekMs 之前）此测试转红：skipToCue 后快照为 null。
    test('skipToCue 顺序保证：seekMs 在前置快照在后，自身快照不被统一清除点自清', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([
        _cue(0, 0, 1900),
        _cue(1, 2000, 3000),
        _cue(2, 3100, 4000),
      ]);

      await c.skipToCue(c.cues[1]);
      // skipToCue 内部经 seekMs（统一清除点）后才置目标——快照必须存活、宽限满。
      expect(c.debugSeekTargetCueIndex, 1,
          reason: 'skipToCue 自己的快照不得被它内部的 seekMs 清除点自清');

      // 前两轮情形 3 保护仍生效：preRoll 落点处 snap 回目标句 N（非 N-1）。
      c.debugUpdateCueForPosition(1820); // 2000-180，落 cue0 区间但应 snap 回 1
      expect(c.currentCueIndex, 1,
          reason: 'preRoll 引导窗口内仍 snap 回点击的目标句（前两轮保护不破坏）');
    });

    // BUG-378：点字幕列表里某句（短句 / 间隔密），skipToCue 的 seek 在途瞬态 tick 读到一个
    // **越过目标句尾**的位置（短句关键帧吸附越过整句 / media_kit seek 吐的中间高位置），
    // 旧实现情形 1（eff>=startMs 旧判据，或 eff>endMs 但无在途宽限保护）会立即清快照、采用
    // findCueIndex 命中的下一句 → 点第 N 句高亮 N+1（多跳一句）。修复：position 首次真正落入
    // 目标句前的在途瞬态，无论在目标句之前还是之后，都受在途 seek 宽限保护、snap 回目标句。
    // 撤掉「越句尾在途也消耗宽限」保护（把 if(eff>targetEndMs) 提前清快照搬回宽限分支之前）
    // 此测试转红：在途越句尾瞬态 → 高亮多跳到下一句。
    test('BUG-378：skipToCue 在途瞬态越过短目标句尾 → 不多跳，snap 回目标句 N（非 N+1）', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      // 短目标句 cue1=[1050,1100]（50ms），下一句 cue2=[1120,2000]。
      c.setCues([
        _cue(0, 0, 1000),
        _cue(1, 1050, 1100),
        _cue(2, 1120, 2000),
      ]);

      // 点第 2 行（index 1）。skipToCue 置目标 1 + 满在途宽限（无 player 时 seek no-op）。
      await c.skipToCue(c.cues[1]);
      expect(c.debugSeekTargetCueIndex, 1);

      // ① 在途瞬态 tick：seek 尚未落到目标句，但读到一个越过 cue1 句尾的位置 1150
      //    （落在下一句 cue2 区间 [1120,2000]）。findCueIndex(1150)=2，旧实现据此多跳 cue2。
      //    在途宽限保护下应 snap 回目标句 1（撑到 seek 真落到 cue1）。
      c.debugUpdateCueForPosition(1150);
      expect(c.currentCueIndex, 1, reason: '在途越句尾瞬态不得把高亮顶到下一句（BUG-378 多跳）');
      expect(c.debugSeekTargetCueIndex, 1, reason: '在途宽限未作废，快照仍在');

      // ② seek 真落到目标句内 1080（preRoll 落点经关键帧吸附进 cue1 区间）：高亮目标句 1，
      //    并作废在途宽限（position 已首次真正落入目标句）。
      c.debugUpdateCueForPosition(1080);
      expect(c.currentCueIndex, 1);
      expect(c.currentCue!.text, 'line1');

      // ③ 落定后正常自然播放越过 cue1 句尾进 cue2：宽限已作废，按真实位置前进，不再钉住。
      c.debugUpdateCueForPosition(1150);
      expect(c.currentCueIndex, 2, reason: '落定后自然越句尾，正常跟随到下一句');
    });

    // BUG-378 对称：播放态点**靠前**的句（当前 position 在更后的句），skipToCue 的 seek 在途，
    // stale tick 先读到旧的（更后的）position——它越过目标句尾。旧实现情形 1 立即清快照、
    // 采用 findCueIndex 命中的旧句 → 高亮停在旧句（点了没反应 / 跳错）。在途宽限保护下应
    // snap 回点击的靠前目标句，撑到 seek 落地。
    test('BUG-378：点靠前句时 stale tick（旧远位置在目标句之后）→ snap 回目标句，不停旧句', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([
        _cue(0, 0, 1000),
        _cue(1, 3000, 4000),
        _cue(2, 6000, 7000),
      ]);

      // 当前在 cue2 播放，点第 1 行（index 0，靠前句）。skipToCue 置目标 0 + 满宽限。
      await c.skipToCue(c.cues[0]);
      expect(c.debugSeekTargetCueIndex, 0);

      // ① stale tick：seek 尚未落地，读到旧的（更后的）position 6500（在 cue2 区间，
      //    远在目标句 0 的句尾 1000 之后）。findCueIndex(6500)=2。在途宽限保护下 snap 回 0。
      c.debugUpdateCueForPosition(6500);
      expect(c.currentCueIndex, 0, reason: '点靠前句的 stale 旧高位置不得把高亮停在旧句（在途宽限保护）');

      // ② seek 落到目标句首 0：高亮目标句 0，作废宽限。
      c.debugUpdateCueForPosition(0);
      expect(c.currentCueIndex, 0);
      expect(c.currentCue!.text, 'line0');
    });
  });
}
