import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// TODO-2389 / TODO-2369：`AudiobookPlayerController.awaitImageChapterPause`
/// 的两个坑。
///
/// TODO-2389（用户可感）：停留用的 Completer 原本是局部变量，只由
/// `_imagePauseTimer` 回调完成，而该定时器在 7 处被 cancel 却不 complete
/// （triggerImagePause / 自身重入 / load / play / pause / stopPlayback /
/// _teardownForDispose）。任一取消点命中 → `await done.future` 永久挂起 →
/// reader `_pauseThroughImageOnlyChapters` 的 finally 永不执行 →
/// `setImageChapterPauseActive(false)` 不执行 → 进程级 `_imageChapterPauseActive`
/// 卡 true → `notifySectionRestoreCompleted` 永久早退 → cue 驱动的跨章推进直到
/// 下次 load 新有声书前彻底失效。
///
/// TODO-2369：停留结束的恢复播放原本是 `await _activateMainPlayer()`，把
/// 「停留结束」和「播放已重新建立」绑死。just_audio 的 `play()` Future 在寻常
/// 路径上可以永远不完成（音频会话激活被拒时 playCompleter 从不 complete；
/// `_sendPlayRequest` 在 playing 已翻回 false 时 defensive-return 丢掉
/// completer），一旦挂住同样把 reader 的 finally 永久钉死。
///
/// harness 注意：mock `load` 必须返回 LoadResponse 并发 ready 事件，否则
/// `_player.pause()` 会卡在平台激活上，测试被 harness 自身挂住而误判。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 停留 1 秒；取消类用例在 200ms 处触发取消，随后必须在远小于剩余停留时长
  /// 的窗口内返回。
  const Duration pauseWindow = Duration(seconds: 1);
  const Duration beforeCancel = Duration(milliseconds: 200);
  const Duration settleAfterCancel = Duration(milliseconds: 400);

  group('TODO-2389 awaitImageChapterPause 在每个取消点都必须返回', () {
    test('对照组：无人取消 → 停留到点 → 恢复播放 → Future 完成', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;
      h.platform.playCalls = 0;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(pauseWindow + settleAfterCancel);

      expect(done, isTrue, reason: '对照组必须完成，证明取消用例断的不是死分支');
      expect(h.platform.playCalls, greaterThan(0), reason: '停留结束应恢复播放');
      h.controller.dispose();
    });

    test('取消点 pause()：用户在插图停留期按暂停', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(beforeCancel);
      h.platform.playCalls = 0;
      await h.controller.pause();
      await Future<void>.delayed(settleAfterCancel);

      expect(done, isTrue, reason: 'pause() 必须成对完成 Completer，await 不得挂起');
      expect(h.platform.playCalls, 0,
          reason: '失效续体绝不能把用户刚暂停的播放又恢复回去（先递增 epoch 再 complete）');
      h.controller.dispose();
    });

    test('取消点 stopPlayback()：退出阅读器', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(beforeCancel);
      h.platform.playCalls = 0;
      unawaited(h.controller.stopPlayback().catchError((Object _) {}));
      await Future<void>.delayed(settleAfterCancel);

      expect(done, isTrue, reason: 'stopPlayback() 必须成对完成 Completer');
      expect(h.platform.playCalls, 0, reason: '退出后不得恢复播放');
      h.controller.dispose();
    });

    test('取消点 play()：用户在停留期按播放', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(beforeCancel);
      await h.controller.play();
      await Future<void>.delayed(settleAfterCancel);

      expect(done, isTrue, reason: 'play() 必须成对完成 Completer');
      h.controller.dispose();
    });

    test('取消点 load()：停留期换书', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(beforeCancel);
      h.platform.playCalls = 0;
      await h.controller.load(
        audiobook: _audiobook(),
        audioFiles: <File>[h.audioFile],
      );
      await Future<void>.delayed(settleAfterCancel);

      expect(done, isTrue, reason: 'load() 必须成对完成 Completer');
      expect(h.platform.playCalls, 0, reason: '换书后旧续体不得恢复播放');
      h.controller.dispose();
    });

    test('取消点 dispose()：控制器销毁', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool done = false;
      unawaited(h.controller.awaitImageChapterPause().then((_) => done = true));
      await Future<void>.delayed(beforeCancel);
      h.platform.playCalls = 0;
      h.controller.dispose();
      await Future<void>.delayed(settleAfterCancel);

      expect(done, isTrue, reason: 'dispose() 必须成对完成 Completer');
      expect(h.platform.playCalls, 0,
          reason: '销毁后续体不得恢复播放，也不得对已 dispose 的 notifier notify');
    });

    test('取消点 awaitImageChapterPause 自身重入：上一轮停留必须被放行', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;

      bool firstDone = false;
      bool secondDone = false;
      unawaited(
        h.controller.awaitImageChapterPause().then((_) => firstDone = true),
      );
      await Future<void>.delayed(beforeCancel);
      unawaited(
        h.controller.awaitImageChapterPause().then((_) => secondDone = true),
      );
      await Future<void>.delayed(settleAfterCancel);

      expect(firstDone, isTrue, reason: '被重入顶掉的上一轮必须立刻返回，不得挂起');
      expect(secondDone, isFalse, reason: '新一轮仍在停留中');
      await Future<void>.delayed(pauseWindow);
      expect(secondDone, isTrue, reason: '新一轮到点后正常完成');
      h.controller.dispose();
    });
  });

  group('TODO-2369 停留结束不得阻塞到播放停止', () {
    test('平台 play 请求永不解析时，awaitImageChapterPause 仍准时返回', () async {
      final _Harness h = await _Harness.create();
      h.controller.imagePauseSec.value = 1;
      // 模拟 just_audio `play()` Future 永不完成的那一类寻常路径（音频会话激活
      // 被拒 / play 请求被 defensive-return 丢掉 completer）。
      h.platform.hangPlay = true;
      h.platform.playCalls = 0;

      bool done = false;
      final Stopwatch sw = Stopwatch()..start();
      unawaited(h.controller.awaitImageChapterPause().then((_) {
        done = true;
        sw.stop();
      }));
      await Future<void>.delayed(pauseWindow + settleAfterCancel);

      expect(done, isTrue, reason: '停留结束的契约是「这张插图看完了」，不能押在播放激活上');
      expect(sw.elapsed, lessThan(pauseWindow + settleAfterCancel),
          reason: '必须在停留窗口结束后立刻返回');
      expect(h.platform.playCalls, greaterThan(0),
          reason: '仍必须真的发起恢复播放（只是不 await）');
      h.controller.dispose();
    });

    test('恢复播放仍走 _activateMainPlayer：stopPlayback 后的门必须挡住', () async {
      final _Harness h = await _Harness.create();
      await h.controller.stopPlayback().catchError((Object _) {});
      h.platform.playCalls = 0;
      await h.controller.play();
      await Future<void>.delayed(settleAfterCancel);

      expect(h.platform.playCalls, 0,
          reason:
              '_stopRequested 门只存在于 _activateMainPlayer，退回裸 _player.play() 会倒退掉它');
      h.controller.dispose();
    });
  });

  group('结构守卫：Timer 与 Completer 必须成对处理', () {
    // 必须扫「去掉注释后的代码」：本文件断言的字面量（裸 cancel、_player.play）
    // 恰好也出现在被测文件的说明性注释里，直接扫原文会把注释当成违规/合规证据，
    // 两个方向的假绿假红都可能。
    final String src = _stripDartComments(
      File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync(),
    );

    test('全文只允许 _invalidateImageChapterPause 里那一处 cancel', () {
      final int helperIdx =
          src.indexOf('void _invalidateImageChapterPause() {');
      expect(helperIdx, isNonNegative, reason: '成对作废的唯一入口必须存在');
      final int helperEnd = src.indexOf('\n  }', helperIdx);
      expect(helperEnd, greaterThan(helperIdx));

      final RegExp cancelSite = RegExp(r'_imagePauseTimer[?!]?\.cancel\(\)');
      final List<int> offsets = cancelSite
          .allMatches(src)
          .map((RegExpMatch m) => m.start)
          .toList(growable: false);
      expect(offsets, isNotEmpty);
      for (final int offset in offsets) {
        expect(
          offset > helperIdx && offset < helperEnd,
          isTrue,
          reason: '裸 cancel（不 complete Completer）会让 awaitImageChapterPause '
              '永久挂起；所有取消点必须走 _invalidateImageChapterPause / '
              '_invalidateReaderTransition。越界位置 offset=$offset',
        );
      }
    });

    test('作废顺序必须是「先递增 epoch，再 complete」', () {
      final int helperIdx =
          src.indexOf('void _invalidateImageChapterPause() {');
      final int helperEnd = src.indexOf('\n  }', helperIdx);
      final String body = src.substring(helperIdx, helperEnd);
      final int epochBump = body.indexOf('_imageChapterPauseEpoch++;');
      final int complete = body.indexOf('pending.complete();');
      expect(epochBump, isNonNegative);
      // 形态不变量（非当前行为差异）：`Completer.complete()` 走微任务，续体总在
      // 本同步块之后才跑，所以今天两种顺序行为相同。锁住它是为了防未来把
      // Completer 换成 `Completer.sync()` / 在两句之间插入 await——那时顺序立刻
      // 变成 load-bearing：旧续体会通过 epoch 校验并把用户刚暂停的播放恢复回去。
      expect(complete, greaterThan(epochBump),
          reason: '作废必须先递增 epoch 再 complete，否则同步唤醒的旧续体会通过 epoch 校验');
    });

    test('awaitImageChapterPause 的恢复播放必须 unawaited 且走 _activateMainPlayer', () {
      final int start =
          src.indexOf('Future<void> awaitImageChapterPause() async {');
      expect(start, isNonNegative);
      final int end = src.indexOf('\n  void holdChapterTransition()', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      expect(body.contains('unawaited(_activateMainPlayer());'), isTrue,
          reason: 'await 会把 reader 跨章 finally 押在播放激活上（TODO-2369）');
      expect(body.contains('await _activateMainPlayer()'), isFalse,
          reason: '不得再出现阻塞形态');
      expect(body.contains('_player.play('), isFalse,
          reason:
              '退回裸 _player.play() 会倒退掉 _stopRequested 门与 _playActivationTail 串行化');
    });
  });
}

/// 把 Dart 源码里的行注释 / 块注释替换成等长空白（保持偏移可读），字符串字面量
/// 内的 `//` 不当注释。
String _stripDartComments(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < source.length) {
    final String ch = source[i];
    if (ch == '/' && i + 1 < source.length) {
      final String next = source[i + 1];
      if (next == '/') {
        while (i < source.length && source[i] != '\n') {
          out.write(' ');
          i++;
        }
        continue;
      }
      if (next == '*') {
        while (i < source.length &&
            !(source[i] == '*' &&
                i + 1 < source.length &&
                source[i + 1] == '/')) {
          out.write(source[i] == '\n' ? '\n' : ' ');
          i++;
        }
        if (i < source.length) {
          out.write('  ');
          i += 2;
        }
        continue;
      }
    }
    if (ch == "'" || ch == '"') {
      final String quote = ch;
      out.write(ch);
      i++;
      while (i < source.length) {
        if (source[i] == r'\') {
          out.write(source[i]);
          if (i + 1 < source.length) out.write(source[i + 1]);
          i += 2;
          continue;
        }
        out.write(source[i]);
        final bool closing = source[i] == quote;
        final bool lineBreak = source[i] == '\n';
        i++;
        if (closing || lineBreak) break;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

class _Harness {
  _Harness({
    required this.controller,
    required this.platform,
    required this.audioFile,
  });

  final AudiobookPlayerController controller;
  final _FakeAudioPlayerPlatform platform;
  final File audioFile;

  static Future<_Harness> create() async {
    final _FakeJustAudioPlatform registry = _installFakeAudioPlatform();
    final AudiobookPlayerController controller = AudiobookPlayerController();
    final File audioFile = File(
      '${Directory.systemTemp.path}/hibiki-image-chapter-pause-2389.mp3',
    );
    if (!audioFile.existsSync()) {
      audioFile.writeAsBytesSync(const <int>[0]);
    }
    addTearDown(() {
      if (audioFile.existsSync()) audioFile.deleteSync();
    });
    await controller.load(
      audiobook: _audiobook(),
      audioFiles: <File>[audioFile],
    );
    final List<AudioCue> cues = <AudioCue>[_sasayakiCue(0, section: 5)];
    controller.setAllBookCues(cues);
    controller.setChapterCues(cues);
    controller.followAudio.value = true;
    await controller.play();
    return _Harness(
      controller: controller,
      platform: registry.player!,
      audioFile: audioFile,
    );
  }
}

AudioCue _sasayakiCue(int startMs, {required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SasayakiMatchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: 0,
      normCharEnd: 10,
    )
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
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
  const MethodChannel audioSessionChannel =
      MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  final JustAudioPlatform previousPlatform = JustAudioPlatform.instance;
  final _FakeJustAudioPlatform platform = _FakeJustAudioPlatform();
  JustAudioPlatform.instance = platform;
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
  return platform;
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeAudioPlayerPlatform? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player ??= _FakeAudioPlayerPlatform(request.id);
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

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  int playCalls = 0;
  int pauseCalls = 0;

  /// 平台 play 请求永不解析，模拟 just_audio 里 playCompleter 从不 complete 的
  /// 那一类路径（TODO-2369）。
  bool hangPlay = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (!_events.isClosed) {
      _events.add(PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: const Duration(seconds: 30),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ));
    }
    return LoadResponse(duration: const Duration(seconds: 30));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauseCalls++;
    return PauseResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    playCalls++;
    if (hangPlay) return Completer<PlayResponse>().future;
    return Future<PlayResponse>.value(PlayResponse());
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async =>
      SetSkipSilenceResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async =>
      SetWebCrossOriginResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
