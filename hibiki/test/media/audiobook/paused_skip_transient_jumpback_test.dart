import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'helpers/audiobook_test_harness.dart';

/// BUG: 有声书暂停后点「前进/后退」(按句模式) 会跳转两次——下一句会跳回这一句、
/// 上一句乱跳。
///
/// 根因：`skipToCue` 已把目标 cue 作为权威值写入 `_currentCue`，但 `seek(index:)`
/// 在 `preload:false` 下会吐瞬态位置。暂停态下没有真实播放推进，而显式 seek 抑制窗
/// 的「落定」判据是 `posMs >= targetMs - 容差`：
///   - 前向 seek（下一句）：暂停在本句末尾时，旧位置已落进 `target-容差` 窗内 →
///     误判落定 → 清旗 → 用旧位置 findCueIndex 重解析回旧句。
///   - 后向 seek（上一句）：旧位置本就高于 target → 同样误判落定 → 乱跳。
///
/// 修复：`_updateCurrentCue` 在 `_explicitSeekInFlight && !playing` 时一律抑制瞬态、
/// 保留权威 cue、不清旗，待真正播放后首帧到达 target 再正常落定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paused explicit-seek transient must not override authoritative cue',
      () {
    test('暂停态点下一句：seek 瞬态(旧位置接近本句末尾)不把高亮拉回当前句', () async {
      final AudiobookPlayerController controller =
          await _loadController(<AudioCue>[
        _cue(0), // cue0: [0, 1000]
        _cue(1000), // cue1: [1000, 2000]
      ]);

      // 用户暂停在 cue0 末尾，点「下一句」→ 权威跳到 cue1。
      await controller.skipToCue(controller.chapterCuesSnapshot[1]);
      expect(controller.currentCue?.startMs, 1000,
          reason: 'skipToCue 必须立即写入权威 cue1');

      // seek 的瞬态 tick 仍停在旧位置 800（在 cue0 内，且距 cue1.start=1000
      // 只有 200ms，落进 target-容差(300ms) 窗内）。暂停态不得据此重解析。
      controller.debugUpdateCueForPosition(800);

      expect(controller.currentCue?.startMs, 1000,
          reason: '暂停态瞬态 tick 不能把权威 cue1 覆盖回 cue0');

      controller.dispose();
    });

    test('暂停态点上一句：seek 瞬态(旧位置高于目标)不把高亮拉回当前句', () async {
      final AudiobookPlayerController controller =
          await _loadController(<AudioCue>[
        _cue(0), // cue0
        _cue(1000), // cue1
        _cue(2000), // cue2
      ]);

      // 用户暂停在 cue2，点「上一句」→ 权威跳到 cue1。
      await controller.skipToCue(controller.chapterCuesSnapshot[1]);
      expect(controller.currentCue?.startMs, 1000);

      // 后向 seek：旧位置 2100（在 cue2 内）远高于 target(cue1.start=1000)，
      // reached 判据恒真 → 旧逻辑会误判落定并重解析回 cue2。
      controller.debugUpdateCueForPosition(2100);

      expect(controller.currentCue?.startMs, 1000,
          reason: '暂停态后向 seek 的旧高位置瞬态不能把权威 cue1 覆盖回 cue2');

      controller.dispose();
    });
  });

  // 源码守卫：暂停态抑制必须接在显式 seek guard 内，删掉就会让「跳两次」复发。
  test('源码守卫：_updateCurrentCue 显式 seek 段内有暂停态抑制', () {
    final String src = File(
      '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();
    final int guardIdx = src.indexOf('if (_explicitSeekInFlight) {');
    expect(guardIdx, greaterThanOrEqualTo(0));
    final int reachedIdx = src.indexOf(
      'reachedExplicitSeekTargetForTesting(',
      guardIdx,
    );
    final String block = src.substring(guardIdx, reachedIdx);
    expect(block.contains('!_player.playing'), isTrue,
        reason:
            '显式 seek guard 内、reached 判定之前必须有暂停态抑制 (!_player.playing) return;');
  });
}

Future<AudiobookPlayerController> _loadController(List<AudioCue> cues) async {
  installHangingAudioPlatform();
  final AudiobookPlayerController controller = AudiobookPlayerController();
  final File audioFile =
      createFakeAudioFile('hibiki-paused-skip-${cues.length}.mp3');
  await controller.load(
    audiobook: fakeAudiobook(),
    audioFiles: <File>[audioFile],
  );
  controller.setChapterCues(cues);
  return controller;
}

AudioCue _cue(int startMs) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
}
