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

  // BUG-179：安卓视频退出重进不从上次位置继续。
  //
  // 恢复 seek 守护 _restoreTargetMs：seek 落地前禁止三个写入点用过渡期小值（0/小值）
  // 覆盖真实进度。旧实现的守护**只**靠「position 追上目标」清除；seek 在慢设备 / 软解
  // （Android 尤甚）上若被 libmpv 丢弃、position 停在 0 附近从头播，守护**永久**不清 →
  // 这一程进度全被跳过（没回到上次位置，也没记住这次）。修复给守护加有界宽限：连续
  // _restoreGuardGraceTicks 次仍未追上目标即放弃守护，让写入恢复正常。
  group('VideoPlayerController BUG-179 恢复守护有界宽限', () {
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
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: 0, positionMs: 500),
          1,
        );
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: 1, positionMs: 2500),
          2,
        );
      });

      test('已在末句：返回 null（不动）', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: 2, positionMs: 4500),
          isNull,
        );
      });

      test('gap（idx=-1）里 cue0 与 cue1 之间：下一句 = cue1，不打回原点', () {
        // pos=1500 落在 cue0(0-1000) 与 cue1(2000-3000) 的 gap。旧实现会给 0。
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 1500),
          1,
        );
      });

      test('gap 在 cue1 与 cue2 之间：下一句 = cue2', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 3500),
          2,
        );
      });

      test('早于首句（开头静音）：下一句 = 首句 0', () {
        // 这里跳 0 是对的（用户本就在 0 之前），但不是「从 gap 打回原点」。
        final lateStart = <AudioCue>[_cue(0, 1000, 2000), _cue(1, 3000, 4000)];
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: lateStart, currentCueIndex: -1, positionMs: 200),
          0,
        );
      });

      test('gap 在末句之后：返回 null（已无下一句）', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 9000),
          isNull,
        );
      });

      test('空 cue 列表：null', () {
        expect(
          VideoPlayerController.nextCueIndexFor(
              cues: const <AudioCue>[], currentCueIndex: -1, positionMs: 0),
          isNull,
        );
      });
    });

    group('prevCueIndexFor', () {
      test('定位到当前 cue：取前一条', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: 2, positionMs: 4500),
          1,
        );
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: 1, positionMs: 2500),
          0,
        );
      });

      test('已在首句：返回 null（不动）', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: 0, positionMs: 500),
          isNull,
        );
      });

      test('gap（idx=-1）在 cue1 与 cue2 之间：上一句 = cue1，不越界 no-op', () {
        // pos=3500 落在 cue1(2000-3000) 与 cue2(4000-5000) 的 gap。
        // 旧实现 -1-1=-2 恒 no-op；新决策回退到 gap 之前那条 = cue1。
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 3500),
          1,
        );
      });

      test('gap 在 cue0 与 cue1 之间：上一句 = cue0', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 1500),
          0,
        );
      });

      test('早于首句：上一句落首句 0（不返回负值）', () {
        final lateStart = <AudioCue>[_cue(0, 1000, 2000), _cue(1, 3000, 4000)];
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: lateStart, currentCueIndex: -1, positionMs: 200),
          0,
        );
      });

      test('gap 在末句之后：上一句 = 末句', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: cues, currentCueIndex: -1, positionMs: 9000),
          2,
        );
      });

      test('空 cue 列表：null', () {
        expect(
          VideoPlayerController.prevCueIndexFor(
              cues: const <AudioCue>[], currentCueIndex: -1, positionMs: 0),
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
          currentCueIndex: 2,
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
          currentCueIndex: 1,
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
          currentCueIndex: -1,
          positionMs: 8000,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.timeSeek(-3000));
      });

      test('阈值边界：恰好等于 Xs 仍跳句（> 才退化）', () {
        // 上一句 = cue0(0)，pos=3000 → gap = 3000 == 3*1000，不 > 阈值 → 跳句。
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: <AudioCue>[_cue(0, 0, 1000), _cue(1, 5000, 6000)],
          currentCueIndex: 1,
          positionMs: 3000,
          seekSeconds: 3,
        );
        expect(d, const PrevSeekDecision.cue(0));
      });

      test('已在首句：none（不强行回退到负位置）', () {
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          currentCueIndex: 0,
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
          currentCueIndex: -1,
          positionMs: 0,
          seekSeconds: 3,
        );
        expect(d, PrevSeekDecision.none);
      });

      test('seekSeconds<=0 防御：阈值失效，恒跳句', () {
        final PrevSeekDecision d = VideoPlayerController.prevSeekDecisionFor(
          cues: farCues,
          currentCueIndex: 1,
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
        VideoPlayerController.nextCueIndexFor(
            cues: c.cues, currentCueIndex: c.currentCueIndex, positionMs: 1500),
        1,
      );
    });
  });
}
