import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

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
///
/// 位置值断言一律走 [_LivePositionWindow]，**不要**写 `equals(70000)` 这类精确
/// 相等——理由见该类文档（just_audio 的 position 按墙钟外推，精确相等在满载机器
/// 上必然随机红）。
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

  Audiobook ab() => Audiobook()
    ..bookKey = 'book'
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';

  File makeFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  _FakePlatform installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    final _FakePlatform p = _FakePlatform();
    JustAudioPlatform.instance = p;
    addTearDown(() => JustAudioPlatform.instance = prev);
    return p;
  }

  // ── baselines：证明控制器层的恢复 / 周期保存本身没坏 ────────────────────

  test('baseline: load(initialPositionMs) restores position, not 0', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-a.mp3')],
      initialPositionMs: 65000,
    );

    expect(c.position.inMilliseconds, 65000);
  });

  test('baseline: priming cues after load must not clobber savedMs with 0',
      () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-b.mp3')],
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
    final _FakePlatform plat = installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-c.mp3')],
      initialPositionMs: 0,
    );
    c.setChapterCues(<AudioCue>[cue(0), cue(1000), cue(2000), cue(3000)]);

    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Advance playback to 3s: the periodic save persists the position once the
    // whole-second changes (the playing position extrapolates a few ms past).
    final _LivePositionWindow advancedTo3s =
        _LivePositionWindow.openedBefore(3000);
    plat.player!.emit(3000, ProcessingStateMessage.ready, playing: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(writes.where((int w) => w >= 3000), isNotEmpty,
        reason: 'periodic save must persist advancing playback position');

    // App goes to background within the same whole-second: the periodic save
    // would be throttled (wholeSec unchanged), but flushPosition must still
    // write so a subsequent kill keeps the progress.
    writes.clear();
    await c.flushPosition();
    // Exactly one write, carrying the live position extrapolated from the
    // emitted 3000 (see [_LivePositionWindow] for why this is a window and not
    // an equality).
    expect(writes, hasLength(1),
        reason: 'background flush must write once despite the per-second '
            'throttle');
    expect(writes.single, advancedTo3s.matcher,
        reason: 'background flush must persist the latest position');
  });

  test('flushPosition awaits the persistence write (durability)', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-d.mp3')],
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

  test('BUG-1240 stopPlayback persists the live position before stop resets it',
      () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-stop-position-order.mp3')],
      initialPositionMs: 65000,
    );
    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

    await c.stopPlayback();
    await c.disposeAndRelease();

    expect(writes, isNotEmpty);
    expect(
      writes.last,
      65000,
      reason: 'stop 后采样会得到 0；持久化必须发生在 stop 释放播放器之前',
    );
  });

  test('BUG-1240 old queued write completes before the final stop write',
      () async {
    final _FakePlatform plat = installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    final _LivePositionWindow loadedAt65s =
        _LivePositionWindow.openedBefore(65000);
    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-stop-position-queue.mp3')],
      initialPositionMs: 65000,
    );
    await c.play();
    final Completer<void> firstWriteStarted = Completer<void>();
    final Completer<void> allowFirstWrite = Completer<void>();
    final List<int> started = <int>[];
    final List<int> completed = <int>[];
    c.onPositionWrite = (String uid, int ms) async {
      started.add(ms);
      if (started.length == 1) {
        firstWriteStarted.complete();
        await allowFirstWrite.future;
      }
      completed.add(ms);
    };

    final Future<void> oldFlush = c.flushPosition();
    await firstWriteStarted.future;
    final _LivePositionWindow jumpedTo70s =
        _LivePositionWindow.openedBefore(70000);
    plat.player!.emit(70000, ProcessingStateMessage.ready, playing: false);
    await Future<void>.delayed(Duration.zero);

    final Future<void> stop = c.stopPlayback();
    await Future<void>.delayed(Duration.zero);
    // 这一条才是队列不变量：位置值多少无关，关键是**只有一个**写入起跑。
    expect(started, hasLength(1),
        reason: 'the final write must queue behind the older in-flight write');
    // 窗口在这里定格复用，后面不再随测试后半程一起变宽。
    final Matcher preJumpPosition = loadedAt65s.matcher;
    expect(started.single, preJumpPosition,
        reason: 'the in-flight write must carry the pre-jump live position');

    allowFirstWrite.complete();
    await oldFlush;
    await stop;
    expect(started.first, preJumpPosition);
    expect(started.skip(1), everyElement(jumpedTo70s.matcher),
        reason: 'every write queued after the jump must carry the new '
            'position, never the stale pre-jump one');
    expect(completed, started,
        reason: 'DB/cache completion order must match capture order');
  });

  test('BUG-1240 flush failure is surfaced only after playback is stopped',
      () async {
    final _FakePlatform plat = installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-stop-position-write-error.mp3')],
      initialPositionMs: 42000,
    );
    await c.play();
    c.onPositionWrite = (String uid, int ms) async {
      throw StateError('write failed');
    };
    final int disposeBefore = plat.disposePlayerCalls;

    await expectLater(c.stopPlayback(), throwsStateError);
    expect(plat.disposePlayerCalls, greaterThan(disposeBefore),
        reason: 'a persistence error must never leave native playback alive');
  });

  test('BUG-1240 source order keeps flush before both stop calls', () {
    final String source = File(
      '${Directory.current.path}/../packages/hibiki_audio/lib/src/audiobook/'
      'audiobook_controller.dart',
    ).readAsStringSync();
    final int start =
        source.indexOf('Future<void> _stopPlaybackOnce() async {');
    final int end = source.indexOf(
      'bool get debugMainPlayerPlaying',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);
    final int flushAt = body.indexOf('await flushPosition();');
    final int mainStopAt = body.indexOf('_player.stop()');
    final int clipStopAt = body.indexOf('clip.stop()');
    expect(flushAt, greaterThanOrEqualTo(0));
    expect(flushAt, lessThan(mainStopAt));
    expect(flushAt, lessThan(clipStopAt));
    expect(
      body.substring(mainStopAt),
      isNot(contains('_maybeSavePosition(force: true)')),
      reason: '释放后不得再用归零位置覆盖刚写穿的值',
    );
  });
}

/// 播放位置断言的**物理上界**计算器。
///
/// just_audio 播放中的 `AudioPlayer.position` 是按墙钟外推出来的：
///
///     position = 最近一次平台事件的 updatePosition
///              + (DateTime.now() − 该事件的 updateTime) × speed
///
/// （just_audio 0.9.x `AudioPlayer._getPositionFor`）。所以控制器写出去的位置
/// **永远不可能精确等于**测试 emit 的那个整数：从 emit 到控制器采样之间过了多少
/// 真实时间，写出去的值就大多少毫秒。机器一满载，70000 就变成 70001，
/// `equals(70000)` 必然随机红——坏的是**判据**，不是被测代码。
///
/// 这里不拍脑袋加一个 ±N 的容差，而是用 just_audio 自己那把钟（`DateTime.now`）
/// 量出「事件发生之前」到「断言之时」这段真实经过时间 `elapsed`，得到该值在物理上
/// 唯一允许的闭区间：
///
///     [baseMs, baseMs + elapsed]
///
/// 下界 = 外推量非负；上界 = 采样时刻不可能晚于断言时刻，而 `speed` 是默认的 1.0，
/// 所以外推毫秒数不可能超过 `elapsed`。机器越慢区间越宽，恰好抵消外推变大，因此
/// 不会 flaky；同时任何**来源错误**的值——stop 归零后的 0、上一段位置 65000、
/// 压根没写——都落在窗口之外，守卫强度不变（见本文件的变异实测）。
class _LivePositionWindow {
  /// 必须在触发该位置的平台事件 **之前** 构造：只有 `_openedAt` 不晚于事件的
  /// `updateTime`，上界才成立。
  _LivePositionWindow.openedBefore(this.baseMs) : _openedAt = DateTime.now();

  /// 平台事件里那个精确的位置（外推的起点）。
  final int baseMs;

  final DateTime _openedAt;

  /// 在断言点求值：截至此刻，外推最多只能走到 `baseMs + elapsed`。
  Matcher get matcher => inInclusiveRange(
        baseMs,
        baseMs + DateTime.now().difference(_openedAt).inMilliseconds,
      );
}

class _FakePlatform extends JustAudioPlatform {
  _FakePlayer? player;
  int disposePlayerCalls = 0;
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakePlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    disposePlayerCalls++;
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  bool _disposed = false;

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: const Duration(seconds: 100),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
          SetWebCrossOriginRequest request) async =>
      SetWebCrossOriginResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }
}
