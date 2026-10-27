import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';

/// 假播放器：`play()` 的 Future 按 [spansPlayback] 模拟两种后端——
/// 原生（ExoPlayer / AVPlayer，just_audio 原生侧把 play 结果挂到暂停 / 播完 / 释放）
/// 与 media_kit（请求被接受就返回）。只实现 [DesktopAudioPlayback] 用到的成员。
class _FakePlayer implements AudioPlayer {
  _FakePlayer({required this.spansPlayback});

  final bool spansPlayback;
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast(sync: true);
  PlayerState _state = PlayerState(false, ProcessingState.idle);
  Completer<void>? _pendingPlay;

  final List<String> calls = <String>[];
  String? loaded;

  void _emit(PlayerState s) {
    _state = s;
    _states.add(s);
  }

  void _releasePlay() {
    final Completer<void>? c = _pendingPlay;
    _pendingPlay = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 当前片段自然播完。
  void finishClip() {
    _emit(PlayerState(true, ProcessingState.completed));
    _releasePlay();
  }

  @override
  Stream<PlayerState> get playerStateStream => Stream<PlayerState>.multi((
    MultiStreamController<PlayerState> c,
  ) {
    c.add(_state);
    final StreamSubscription<PlayerState> sub = _states.stream.listen(c.add);
    c.onCancel = sub.cancel;
  });

  @override
  Future<void> stop() async {
    calls.add('stop');
    _emit(PlayerState(false, ProcessingState.idle));
    _releasePlay();
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    calls.add('load:$filePath');
    loaded = filePath;
    _emit(PlayerState(false, ProcessingState.ready));
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() {
    calls.add('play:$loaded');
    _emit(PlayerState(true, ProcessingState.ready));
    if (!spansPlayback) return Future<void>.value();
    final Completer<void> c = Completer<void>();
    _pendingPlay = c;
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 让排队的异步链跑完（假播放器的 await 全是已完成的 Future）。
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('N-JACNGS-K / MljlXfzZzL: native play() Future spans the clip', () {
    test('stop() interrupts a clip that is still playing', () async {
      final _FakePlayer player = _FakePlayer(spansPlayback: true);
      DesktopAudioPlayback.debugReset(
        player: player,
        playFutureSpansPlayback: true,
      );

      bool? finished;
      unawaited(
        DesktopAudioPlayback.playFileToEnd(
          'a.mp3',
        ).then((bool v) => finished = v),
      );
      await _settle();
      expect(player.calls, contains('play:a.mp3'));
      expect(finished, isNull, reason: 'clip a is still playing');

      // 换卡：停掉上一张卡的音频。停必须立即生效，不能排在整段播放之后。
      bool stopped = false;
      unawaited(DesktopAudioPlayback.stop().then((_) => stopped = true));
      await _settle();
      expect(
        stopped,
        isTrue,
        reason:
            'stop() must not wait for the native play() Future, which only '
            'settles when the clip ends',
      );
      expect(finished, isFalse, reason: 'interrupted, not played to the end');
    });

    test('the next clip replaces a playing one immediately', () async {
      final _FakePlayer player = _FakePlayer(spansPlayback: true);
      DesktopAudioPlayback.debugReset(
        player: player,
        playFutureSpansPlayback: true,
      );

      bool? firstFinished;
      unawaited(
        DesktopAudioPlayback.playFileToEnd(
          'a.mp3',
        ).then((bool v) => firstFinished = v),
      );
      await _settle();
      unawaited(DesktopAudioPlayback.playFileToEnd('b.mp3'));
      await _settle();
      expect(
        player.calls,
        containsAllInOrder(<String>['play:a.mp3', 'stop', 'play:b.mp3']),
        reason: 'b must start without waiting for a to play to its end',
      );
      expect(firstFinished, isFalse);
    });

    test('a clip that plays to the end still reports completion', () async {
      final _FakePlayer player = _FakePlayer(spansPlayback: true);
      DesktopAudioPlayback.debugReset(
        player: player,
        playFutureSpansPlayback: true,
      );
      final Future<bool> done = DesktopAudioPlayback.playFileToEnd('a.mp3');
      await _settle();
      player.finishClip();
      expect(await done, isTrue);
    });
  });

  test(
    'backend split matches the platforms media_kit takes over in main.dart',
    () {
      // justAudioUsesMediaKitBackend = Windows / Linux = JustAudioMediaKit's
      // default platform flags. Passing platform flags in main.dart would move
      // that line and must update the getter too.
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('JustAudioMediaKit.ensureInitialized();'));
    },
  );

  group('media_kit backend keeps play() inside the serial body (BUG-342)', () {
    test('the next cycle waits for the accepted play()', () async {
      final _FakePlayer player = _FakePlayer(spansPlayback: false);
      DesktopAudioPlayback.debugReset(
        player: player,
        playFutureSpansPlayback: false,
      );
      final Future<bool> done = DesktopAudioPlayback.playFileToEnd('a.mp3');
      await _settle();
      player.finishClip();
      expect(await done, isTrue);
      expect(player.calls, <String>['stop', 'load:a.mp3', 'play:a.mp3']);
    });
  });
}
