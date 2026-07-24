import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'helpers/audiobook_test_harness.dart';

/// BUG-032：歌词模式播放中进程被杀，音频进度归零。
///
/// 根因不在控制器本身（load 能正确恢复 savedMs、播放中周期保存也能写出新值，
/// 见下面两条基线），而在「退到后台→被杀」这条生命周期：dispose 的 force-save
/// 在硬杀场景不执行，周期保存又是 fire-and-forget（可能没 commit 就被回收）。
/// 修复给控制器加了一个**可 await 到落库**的 [AudiobookPlayerController.flushPosition]，
/// reader 页在 `didChangeAppLifecycleState(paused/inactive)` 里调用它，把退到
/// 后台那一刻的播放位置写穿。
///
/// 这条测试钉住 flushPosition 的两个关键性质：
///  1) 即使整秒没变也 **force** 写（不被周期节流吞掉）；
///  2) 返回的 Future **await 到写库真正完成**（durability 保证）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AudioCue cue(int startMs) => AudioCue()
    ..id = startMs
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;

  // ── baselines：证明控制器层的恢复 / 周期保存本身没坏 ────────────────────

  test('baseline: load(initialPositionMs) restores position, not 0', () async {
    installEmittingAudioPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: fakeAudiobook(),
      audioFiles: <File>[createFakeAudioFile('hibiki-flush-a.mp3')],
      initialPositionMs: 65000,
    );

    expect(c.position.inMilliseconds, 65000);
  });

  test('baseline: priming cues after load must not clobber savedMs with 0',
      () async {
    installEmittingAudioPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: fakeAudiobook(),
      audioFiles: <File>[createFakeAudioFile('hibiki-flush-b.mp3')],
      initialPositionMs: 65000,
    );

    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
    c.setChapterCues(<AudioCue>[cue(60000), cue(65000), cue(70000)]);

    expect(writes, isNot(contains(0)));
  });

  // ── the actual fix ───────────────────────────────────────────────────

  test('flushPosition force-saves the current position even at the same second',
      () async {
    final EmittingFakeAudioPlatform plat = installEmittingAudioPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: fakeAudiobook(),
      audioFiles: <File>[createFakeAudioFile('hibiki-flush-c.mp3')],
      initialPositionMs: 0,
    );
    c.setChapterCues(<AudioCue>[cue(0), cue(1000), cue(2000), cue(3000)]);

    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Advance playback to 3s: the periodic save persists the position once the
    // whole-second changes (the playing position extrapolates a few ms past).
    plat.player!.emit(3000);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(writes.where((int w) => w >= 3000), isNotEmpty,
        reason: 'periodic save must persist advancing playback position');

    // App goes to background within the same whole-second: the periodic save
    // would be throttled (wholeSec unchanged), but flushPosition must still
    // write so a subsequent kill keeps the progress.
    writes.clear();
    await c.flushPosition();
    // Exactly one write, carrying the live position within the same 3s window
    // (the playing position extrapolates a few ms past the emitted 3000).
    expect(writes, hasLength(1),
        reason: 'background flush must write once despite the per-second '
            'throttle');
    expect(writes.single, inInclusiveRange(3000, 3999),
        reason: 'background flush must persist the latest position');
  });

  test('flushPosition awaits the persistence write (durability)', () async {
    installEmittingAudioPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: fakeAudiobook(),
      audioFiles: <File>[createFakeAudioFile('hibiki-flush-d.mp3')],
      initialPositionMs: 12000,
    );

    final Completer<void> writeStarted = Completer<void>();
    final Completer<void> allowWrite = Completer<void>();
    bool writeFinished = false;
    c.onPositionWrite = (String uid, int ms) async {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await allowWrite.future;
      writeFinished = true;
    };

    final Future<void> flush = c.flushPosition();
    await writeStarted.future;
    expect(writeFinished, isFalse,
        reason: 'flushPosition must not return before the write completes');

    allowWrite.complete();
    await flush;
    expect(writeFinished, isTrue);
  });
}
