import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../../helpers/source_guard.dart';

/// BUG-3796（控制器侧两条）：
///
/// ② 显式跳句（[AudiobookPlayerController.skipToCue] / `playCueOnce`）在 seek 之后
///    无条件 `_chapterTransition = false`，把 reader 侧**仍在飞**的跨章导航的守卫提前
///    放掉。守卫只属于那次导航，只能由它的落地回执 / 中止信号释放；跳句在守卫期间
///    被挡下的跨章判定改由落地回执补判。
/// ③ 有声书面板「章节」tab 跳章回弹：跳章在飞期间音频仍在旧章往下播——
///    (a) 换句即解除手动导航护栏，新章落地的回执按旧位置重算出旧章的句子并发跨章；
///    (b) 回执落在面板那次 seek 的平台往返窗口里时，`currentIndex` 仍是 seek 前的
///        文件（just_audio 只乐观更新位置），`notifySectionRestoreCompleted` 清掉显式
///        seek 抑制后按「旧文件 + 新位置」重算，同样解析出旧章的句子。
///    两条都把刚跳到新章的 reader 拽回旧章。
///
/// 用真控制器 + 可控的假 just_audio 平台（seek 可挂起、文件下标在平台返回后才变）
/// 复现，断言跨章请求（`onCrossChapter`）序列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 文件 0 = 第 5 章（旧章），文件 1 = 第 9 章（面板要跳去的新章）。
  List<AudioCue> bookCues() => <AudioCue>[
    _cue(file: 0, startMs: 0, section: 5),
    _cue(file: 0, startMs: 1000, section: 5),
    _cue(file: 0, startMs: 2000, section: 5),
    _cue(file: 1, startMs: 0, section: 9),
    _cue(file: 1, startMs: 1000, section: 9),
  ];

  group('③ 面板「章节」tab 跳章不回弹', () {
    test('跳章回执落在 seek 平台往返窗口内：不按 seek 前的文件重算、不发旧章跨章', () async {
      final _Harness h = await _Harness.create(bookCues());
      final AudioCue target = h.cue(file: 1, startMs: 0);

      // 面板：登记组合操作 → 手动跳章（reader 当前章同步改成 9）→ seek 音频。
      h.controller.holdCrossChapterUntilCallerSeek();
      h.controller.noteManualReaderNavigation();
      h.readerSection = 9;
      h.platform.player!.holdSeeks();
      final Future<void> skip = h.controller.skipToCue(
        target,
        callerPositionsReader: true,
      );
      await pumpEventQueue();

      // 跳章落地回执先到（seek 尚未返回，平台文件下标仍是 0）。
      h.controller.notifySectionRestoreCompleted(
        currentReaderSection: 9,
        success: true,
      );
      expect(
        h.crossRequests,
        isEmpty,
        reason: 'seek 未返回时按「旧文件 + 新位置」重算会解析出第 5 章的句子并发跨章（回弹）',
      );

      h.platform.player!.releaseSeeks();
      await skip;
      await pumpEventQueue();
      expect(h.controller.currentCue, same(target));
      expect(h.crossRequests, isEmpty);
    });

    test('跳章在飞期间音频换句：seek 发出前不发旧章跨章', () async {
      final _Harness h = await _Harness.create(bookCues());
      final AudioCue target = h.cue(file: 1, startMs: 0);

      h.controller.holdCrossChapterUntilCallerSeek();
      h.controller.noteManualReaderNavigation();
      h.readerSection = 9;
      // 跳章在飞，旧章音频推进到下一句：手动护栏只护跳章那一刻的那一句。
      h.controller.debugUpdateCueForPosition(2500);
      // 跳章先落地（seek 还没开始）。
      h.controller.notifySectionRestoreCompleted(
        currentReaderSection: 9,
        success: true,
      );
      expect(h.crossRequests, isEmpty, reason: '组合操作的 seek 发出前，按旧章位置判出的跨章就是回弹');

      await h.controller.skipToCue(target, callerPositionsReader: true);
      await pumpEventQueue();
      expect(h.controller.crossChapterHeldForCallerSeekForTesting, isFalse);
      expect(h.controller.currentCue, same(target));
      expect(h.crossRequests, isEmpty);
    });

    test('对照：不登记组合操作时，同一序列确实会对旧章发跨章（证明上面不是空转）', () async {
      final _Harness h = await _Harness.create(bookCues());
      h.controller.noteManualReaderNavigation();
      h.readerSection = 9;
      h.controller.debugUpdateCueForPosition(2500);
      expect(h.crossRequests, <int>[5]);
    });
  });

  group('② 显式跳句不提前放掉 reader 在飞导航的守卫', () {
    test('skipToCue 到在飞导航的目标章：守卫保持到落地回执', () async {
      final _Harness h = await _Harness.create(bookCues());
      // 跨章导航（5 → 9）在飞：reader 已同步改写当前章，回执未到。
      h.readerSection = 9;
      h.controller.holdChapterTransition();

      await h.controller.skipToCue(h.cue(file: 1, startMs: 1000));
      await pumpEventQueue();
      expect(
        h.controller.chapterTransitionHeldForTesting,
        isTrue,
        reason: '守卫属于在飞的那次导航，跳句不得替它释放',
      );

      h.controller.notifySectionRestoreCompleted(
        currentReaderSection: 9,
        success: true,
      );
      expect(h.controller.chapterTransitionHeldForTesting, isFalse);
      expect(h.crossRequests, isEmpty);
    });

    test('skipToCue 到别的章：守卫期间不跨章，落地回执补判一次', () async {
      final _Harness h = await _Harness.create(bookCues());
      h.readerSection = 9;
      h.controller.holdChapterTransition();

      // 守卫期间（导航去 9）用户跳回第 5 章的句子（暂停态）。
      await h.controller.skipToCue(h.cue(file: 0, startMs: 1000));
      await pumpEventQueue();
      expect(h.controller.chapterTransitionHeldForTesting, isTrue);
      expect(h.crossRequests, isEmpty, reason: '导航还没落地，不得并发第二次跨章');

      h.controller.notifySectionRestoreCompleted(
        currentReaderSection: 9,
        success: true,
      );
      expect(h.crossRequests, <int>[5], reason: '落地后补判被守卫挡下的那次跨章：文字跟到音频所在章');
    });

    test('源码：skipToCue / playCueOnce / 两条整列 seek 不再清跨章守卫', () {
      final String src = maskComments(
        File(
          'lib/src/media/audiobook/audiobook_controller.dart',
        ).readAsStringSync(),
      );
      for (final String signature in <String>[
        'Future<void> skipToCue(',
        'Future<void> playCueOnce(',
        'Future<void> restoreToFileOffset(',
        'Future<void> replaceStreamSources(',
      ]) {
        final String body = methodBody(src, signature);
        expect(
          containsCodeLine(body, '_chapterTransition = false;'),
          isFalse,
          reason: '$signature 不得释放 reader 侧导航持有的跨章守卫',
        );
      }
    });
  });

  group('⑧ 平台 seek 在途窗口的生命周期', () {
    test('平台 seek 抛错：finally 关窗', () async {
      final _Harness h = await _Harness.create(bookCues());
      h.platform.player!.throwNextSeek();
      await expectLater(
        h.controller.skipToCue(h.cue(file: 0, startMs: 0)),
        throwsA(isA<PlatformException>()),
      );
      expect(h.controller.explicitSeekPlatformPendingForTesting, isFalse);
    });

    test('一次永不返回的 seek 被下一次显式 seek 取代：窗口跟着最新那次关', () async {
      final _Harness h = await _Harness.create(bookCues());
      await h.controller.play();
      // 第一次 seek 的回执永远不来（Android just_audio：dispose / 落 STATE_ENDED 都不回）。
      h.platform.player!.holdSeeks();
      unawaited(h.controller.skipToCue(h.cue(file: 0, startMs: 0)));
      await pumpEventQueue();
      expect(h.controller.explicitSeekPlatformPendingForTesting, isTrue);

      final AudioCue next = h.cue(file: 0, startMs: 2000);
      await h.controller.skipToCue(next);
      await pumpEventQueue();
      expect(
        h.controller.explicitSeekPlatformPendingForTesting,
        isFalse,
        reason: '计数实现会被挂起的那次 seek 永久卡在 >0，cue 从此不再跟随',
      );
      h.controller.debugUpdateCueForPosition(2100);
      expect(h.controller.explicitSeekInFlightForTesting, isFalse);
      expect(h.controller.currentCue, same(next));
      h.platform.player!.releaseSeeks();
    });

    test('seekMs（手动改位置）取代挂起的显式 seek 窗口', () async {
      final _Harness h = await _Harness.create(bookCues());
      h.platform.player!.holdSeeks();
      unawaited(h.controller.skipToCue(h.cue(file: 0, startMs: 0)));
      await pumpEventQueue();
      expect(h.controller.explicitSeekPlatformPendingForTesting, isTrue);
      await h.controller.seekMs(2500);
      expect(h.controller.explicitSeekPlatformPendingForTesting, isFalse);
      h.platform.player!.releaseSeeks();
    });

    test('seek 窗口内 reader 重灌 cue：不按 seek 前位置重算、不发旧章跨章', () async {
      final _Harness h = await _Harness.create(bookCues());
      final AudioCue target = h.cue(file: 1, startMs: 0);
      h.controller.holdCrossChapterUntilCallerSeek();
      h.controller.noteManualReaderNavigation();
      h.readerSection = 9;
      h.platform.player!.holdSeeks();
      final Future<void> skip = h.controller.skipToCue(
        target,
        callerPositionsReader: true,
      );
      await pumpEventQueue();
      // 新章文档载入：reader 重灌整书 cue（新对象），随后落地回执。
      h.controller.setChapterCues(bookCues());
      h.controller.notifySectionRestoreCompleted(
        currentReaderSection: 9,
        success: true,
      );
      expect(h.crossRequests, isEmpty);
      h.platform.player!.releaseSeeks();
      await skip;
      await pumpEventQueue();
      expect(h.crossRequests, isEmpty);
      expect(h.controller.currentCue?.audioFileIndex, 1);
    });
  });

  group('⑦ 显式 seek「已到位」只认 seek 之后产生的位置', () {
    test('向后 seek：平台返回前回报的旧位置不算到位，返回后到目标才算', () async {
      final _Harness h = await _Harness.create(bookCues());
      await h.controller.play();
      // 正在播第 5 章第 3 句（2500ms），用户跳回第 1 句（0ms）。
      h.controller.debugUpdateCueForPosition(2500);
      expect(h.controller.currentCue?.startMs, 2000);
      final AudioCue target = h.cue(file: 0, startMs: 0);

      h.platform.player!.holdSeeks();
      final Future<void> skip = h.controller.skipToCue(target);
      await pumpEventQueue();
      // 平台还没执行 seek，tick 报的仍是 seek 前的位置：2500 ≥ 0 − 容差。
      h.controller.debugUpdateCueForPosition(2500);
      expect(
        h.controller.explicitSeekInFlightForTesting,
        isTrue,
        reason: 'seek 前产生的位置不是到位证据（旧判据只看数值，会在这里误判）',
      );

      h.platform.player!.releaseSeeks();
      await skip;
      await pumpEventQueue();
      expect(
        h.controller.currentCue,
        same(target),
        reason: '向后 seek 期间的旧位置不得把权威目标句覆盖回 seek 前那一句',
      );
      expect(h.controller.explicitSeekInFlightForTesting, isTrue);

      // seek 之后平台报到目标附近：判到位、清旗、cue 照常跟随。
      h.controller.debugUpdateCueForPosition(50);
      expect(h.controller.explicitSeekInFlightForTesting, isFalse);
      expect(h.controller.currentCue, same(target));
      h.controller.debugUpdateCueForPosition(1200);
      expect(h.controller.currentCue?.startMs, 1000);
    });

    test('前向 seek：原行为不变（返回后未到目标不放、到目标即放）', () async {
      final _Harness h = await _Harness.create(bookCues());
      await h.controller.play();
      h.controller.debugUpdateCueForPosition(100);
      final AudioCue target = h.cue(file: 0, startMs: 2000);

      await h.controller.skipToCue(target);
      await pumpEventQueue();
      h.controller.debugUpdateCueForPosition(100);
      expect(h.controller.explicitSeekInFlightForTesting, isTrue);
      expect(h.controller.currentCue, same(target));

      h.controller.debugUpdateCueForPosition(1800);
      expect(
        h.controller.explicitSeekInFlightForTesting,
        isFalse,
        reason: '目标 − 容差以内即到位（BUG-061 原判据）',
      );
      expect(h.controller.currentCue?.startMs, 1000);
    });
  });
}

class _Harness {
  _Harness(this.controller, this.platform, this.cues);

  final AudiobookPlayerController controller;
  final _FakeJustAudioPlatform platform;
  final List<AudioCue> cues;
  int readerSection = 5;
  final List<int> crossRequests = <int>[];

  AudioCue cue({required int file, required int startMs}) => cues.firstWhere(
    (AudioCue c) => c.audioFileIndex == file && c.startMs == startMs,
  );

  static Future<_Harness> create(List<AudioCue> cues) async {
    final _FakeJustAudioPlatform platform = _installFakeAudioPlatform();
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    final List<File> files = <File>[
      for (int i = 0; i < 2; i++)
        File('${Directory.systemTemp.path}/fushi-seek-guard-$i.mp3'),
    ];
    for (final File f in files) {
      if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    }
    await controller.load(audiobook: _audiobook(), audioFiles: files);
    controller.setChapterCues(cues);
    final _Harness h = _Harness(
      controller,
      platform,
      controller.chapterCuesSnapshot,
    );
    // 本会话按过一次播放（跟随跨章的前提），随后暂停在第 5 章第 2 句。
    await controller.play();
    await controller.pause();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.debugUpdateCueForPosition(1500);
    expect(controller.currentCue?.startMs, 1000);
    controller.getCurrentReaderSection = () => h.readerSection;
    controller.onCrossChapter = h.crossRequests.add;
    return h;
  }
}

AudioCue _cue({required int file, required int startMs, required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-$section'
    ..sentenceIndex = file * 100 + startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: startMs ~/ 100,
      normCharEnd: startMs ~/ 100 + 5,
    )
    ..text = 'cue $file/$startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = file;
}

Audiobook _audiobook() {
  return Audiobook()
    ..bookKey = 'book'
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';
}

_FakeJustAudioPlatform _installFakeAudioPlatform() {
  const MethodChannel audioSessionChannel = MethodChannel(
    'com.ryanheise.audio_session',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });
  final JustAudioPlatform previous = JustAudioPlatform.instance;
  final _FakeJustAudioPlatform platform = _FakeJustAudioPlatform();
  JustAudioPlatform.instance = platform;
  addTearDown(() => JustAudioPlatform.instance = previous);
  return platform;
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeAudioPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakeAudioPlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

/// 多文件假播放器：文件下标只在 seek 的平台往返结束后才随事件更新（与真机
/// just_audio 一致：`AudioPlayer.seek` 只乐观改位置、不改 currentIndex）。
/// [holdSeeks] 后 seek 挂起，直到 [releaseSeeks]。
class _FakeAudioPlayer extends AudioPlayerPlatform {
  _FakeAudioPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  int _index = 0;
  Completer<void>? _nextGate;
  Completer<void>? _heldGate;
  bool _throwNextSeek = false;

  /// 下一次 seek 挂起，直到 [releaseSeeks]（之后的 seek 照常返回）。
  void holdSeeks() => _nextGate = Completer<void>();

  void releaseSeeks() {
    (_heldGate ?? _nextGate)?.complete();
    _heldGate = null;
    _nextGate = null;
  }

  /// 下一次 seek 抛错（平台 seek 失败）。
  void throwNextSeek() => _throwNextSeek = true;

  void _emit(int ms) {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: ms),
        bufferedPosition: Duration(milliseconds: ms),
        duration: const Duration(seconds: 100),
        icyMetadata: null,
        currentIndex: _index,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _index = request.initialIndex ?? 0;
    _emit(request.initialPosition?.inMilliseconds ?? 0);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (_throwNextSeek) {
      _throwNextSeek = false;
      throw PlatformException(code: 'seek-failed');
    }
    final Completer<void>? gate = _nextGate;
    if (gate != null) {
      _nextGate = null;
      _heldGate = gate;
      await gate.future;
    }
    _index = request.index ?? _index;
    _emit(request.position?.inMilliseconds ?? 0);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async => SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async => SetPreferredPeakBitRateResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async => SetWebCrossOriginResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
