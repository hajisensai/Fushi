import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 引擎在「打开失败 / 取流期间 / 快速连切」下的队列行为（在线插件曲目取流的那一侧由
/// `music_mpv_plugin_stream_real_test.dart` 对真 libmpv 验）。
///
/// 替身后端：[unavailable] 里的曲目 openPair 直接抛「拿不到流」；[gates] 里的曲目 openPair
/// 卡住直到测试放行（模拟取流在路上）。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  final Set<String> unavailable = <String>{};
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  /// 最后一次真正「打开完成」的曲目（模拟播放器里正在放的那首）。
  String? loaded;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    log.add('open:${current.trackUid}');
    final Completer<void>? gate = gates[current.trackUid];
    if (gate != null) await gate.future;
    if (unavailable.contains(current.trackUid)) {
      throw MusicTrackOpenException(
        MusicBackendFailed(
          '${current.trackUid} 需要会员',
          reason: MusicPlaybackFailure.trackUnavailable,
          trackUid: current.trackUid,
        ),
      );
    }
    loaded = current.trackUid;
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => log.add('next:${next?.trackUid}');

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid) => MusicPlayItem(
  trackUid: uid,
  path: 'fushi-music-plugin://p/$uid',
  title: uid,
  durationMs: 200000,
);

List<MusicPlayItem> _queue(List<String> uids) => <MusicPlayItem>[
  for (final String u in uids) _item(u),
];

void main() {
  late _Backend backend;
  late MusicPlayerEngine engine;
  late List<String> started;
  late List<String> skipped;
  late List<MusicBackendFailed> failures;

  setUp(() {
    backend = _Backend();
    started = <String>[];
    skipped = <String>[];
    failures = <MusicBackendFailed>[];
    engine = MusicPlayerEngine(backendFactory: () => backend)
      ..onTrackStarted = ((MusicPlayItem i) => started.add(i.trackUid))
      ..onTrackSkipped = ((MusicPlayItem i, MusicBackendFailed _) =>
          skipped.add(i.trackUid))
      ..onPlaybackFailed = failures.add;
  });
  tearDown(() => engine.dispose());

  Future<void> settle() async {
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('拿不到流的曲目自动跳过，失败曲目不记播放事件', () async {
    backend.unavailable.add('b');
    await engine.playQueue(_queue(<String>['a', 'b', 'c']), startIndex: 1);
    await settle();
    expect(engine.current?.trackUid, 'c');
    expect(engine.isPlaying, isTrue);
    expect(skipped, <String>['b']);
    expect(started, <String>['c'], reason: 'b 没出声，不记播放事件');
    expect(failures, isEmpty, reason: '跳过不是停下，不弹失败提示');
    expect(backend.log, <String>['open:b', 'open:c']);
  });

  test('连续 3 首拿不到流才停，并且只提示一次；再按播放重开当前曲目', () async {
    backend.unavailable.addAll(<String>['a', 'b', 'c']);
    await engine.playQueue(_queue(<String>['a', 'b', 'c', 'd']));
    await settle();
    expect(backend.log, <String>['open:a', 'open:b', 'open:c']);
    expect(engine.current?.trackUid, 'c', reason: '第 3 首失败就停在它上面');
    expect(engine.isPlaying, isFalse);
    expect(skipped, <String>['a', 'b']);
    expect(failures.single.trackUid, 'c');
    expect(engine.lastError, contains('c 需要会员'));
    expect(started, isEmpty);

    // 失败曲目在后端里不存在：按播放必须走重开（重新取流），不是对空播放器发 play。
    backend.unavailable.remove('c');
    backend.log.clear();
    await engine.play();
    expect(backend.log, <String>['open:c']);
    expect(engine.isPlaying, isTrue);
    expect(started, <String>['c']);
  });

  test('队尾拿不到流：不越界，直接停并提示', () async {
    backend.unavailable.add('b');
    await engine.playQueue(_queue(<String>['a', 'b']), startIndex: 1);
    await settle();
    expect(engine.current?.trackUid, 'b');
    expect(skipped, isEmpty);
    expect(failures, hasLength(1));
  });

  test('打开之后才报的失败（流打不开）：当前曲目标记需重开，play 走重开', () async {
    await engine.playQueue(_queue(<String>['a', 'b']));
    backend.controller.add(
      const MusicBackendFailed('Failed to open x', trackUid: 'a'),
    );
    expect(engine.isPlaying, isFalse);
    expect(failures.single.message, 'Failed to open x');
    backend.log.clear();
    await engine.play();
    expect(backend.log, <String>['open:a'], reason: '不能只对空 mpv 调 play');
  });

  test('打开之后才报「拿不到流」也自动跳过；成功出声后连续计数清零', () async {
    await engine.playQueue(_queue(<String>['a', 'b', 'c', 'd', 'e']));
    backend.controller.add(
      const MusicBackendFailed(
        'x',
        reason: MusicPlaybackFailure.trackUnavailable,
        trackUid: 'a',
      ),
    );
    await settle();
    expect(engine.current?.trackUid, 'b');
    // b 真出声了：之前的失败不再累计。
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 1), null),
    );
    for (final String uid in <String>['b', 'c']) {
      backend.controller.add(
        MusicBackendFailed(
          'x',
          reason: MusicPlaybackFailure.trackUnavailable,
          trackUid: uid,
        ),
      );
      await settle();
    }
    expect(engine.current?.trackUid, 'd', reason: 'b、c 连续两次，还没到 3');
    expect(failures, isEmpty);
  });

  test('过期的失败事件（不是当前、也不是下一首）丢弃', () async {
    await engine.playQueue(_queue(<String>['a', 'b', 'c']));
    await engine.skipNext();
    await engine.skipNext();
    backend.controller.add(
      const MusicBackendFailed(
        'late',
        reason: MusicPlaybackFailure.trackUnavailable,
        trackUid: 'a',
      ),
    );
    await settle();
    expect(engine.current?.trackUid, 'c');
    expect(engine.isPlaying, isTrue);
    expect(failures, isEmpty);
    expect(skipped, isEmpty);
  });

  test('预排的下一首在当前曲放完后才发现拿不到流：推进到它、不记播放、接着跳', () async {
    await engine.playQueue(_queue(<String>['a', 'b', 'c']));
    backend.controller.add(
      const MusicBackendFailed(
        'b 无版权',
        reason: MusicPlaybackFailure.trackUnavailable,
        trackUid: 'b',
      ),
    );
    await settle();
    expect(skipped, <String>['b']);
    expect(engine.current?.trackUid, 'c');
    expect(started, <String>['a', 'c']);
  });

  test('快速连切：晚回来的打开作废，显示与出声一致，只记最后一首', () async {
    backend.gates['b'] = Completer<void>();
    backend.gates['c'] = Completer<void>();
    await engine.playQueue(_queue(<String>['a', 'b', 'c', 'd']));
    final Future<void> toB = engine.skipNext();
    expect(engine.resolving, isTrue);
    final Future<void> toC = engine.skipNext();
    final Future<void> toD = engine.skipNext();
    await toD;
    expect(engine.current?.trackUid, 'd');
    expect(engine.resolving, isFalse);
    // b、c 的取流这时才回来：引擎不能把它们当成当前曲目。
    backend.gates['c']!.complete();
    backend.gates['b']!.complete();
    await Future.wait(<Future<void>>[toB, toC]);
    expect(engine.current?.trackUid, 'd');
    expect(engine.resolving, isFalse);
    expect(started, <String>['a', 'd']);
  });

  test('取流期间：resolving 可读并通知；旧曲的位置 / 推进 / 播完不当成新曲的', () async {
    backend.gates['b'] = Completer<void>();
    await engine.playQueue(_queue(<String>['a', 'b', 'c']));
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 30), null),
    );
    final List<bool> seen = <bool>[];
    engine.addListener(() => seen.add(engine.resolving));
    final Future<void> toB = engine.skipNext();
    expect(engine.resolving, isTrue);
    expect(seen.first, isTrue);
    expect(engine.position, Duration.zero);
    backend.controller
      ..add(const MusicBackendPosition(Duration(seconds: 31), null))
      ..add(const MusicBackendAdvanced('c'))
      ..add(const MusicBackendCompleted());
    expect(engine.position, Duration.zero);
    expect(engine.current?.trackUid, 'b');
    backend.gates['b']!.complete();
    await toB;
    expect(engine.resolving, isFalse);
    expect(seen.last, isFalse);
    expect(engine.isPlaying, isTrue);
    expect(started, <String>['a', 'b']);
  });

  test('取流期间按暂停：打开完成后停在暂停', () async {
    backend.gates['b'] = Completer<void>();
    await engine.playQueue(_queue(<String>['a', 'b']));
    final Future<void> toB = engine.skipNext();
    await engine.pause();
    backend.gates['b']!.complete();
    await toB;
    expect(engine.isPlaying, isFalse);
    expect(backend.log.last, 'pause');
  });

  test('流地址被拒的日志行：随包 libmpv 的 curl 流与 FFmpeg http 两种写法都认', () {
    // 真 libmpv 实测（curl 流，error 级）。
    expect(isMusicStreamRejectedLog('HTTP error 403'), isTrue);
    expect(isMusicStreamRejectedLog('HTTP error 410'), isTrue);
    // FFmpeg http 协议（warning / error）。
    expect(isMusicStreamRejectedLog('https: HTTP error 403 Forbidden'), isTrue);
    expect(
      isMusicStreamRejectedLog('Server returned 403 Forbidden (access denied)'),
      isTrue,
    );
    expect(isMusicStreamRejectedLog('HTTP error 404'), isFalse);
    expect(isMusicStreamRejectedLog('HTTP error 4030'), isFalse);
    expect(
      isMusicStreamRejectedLog('Failed to open http://127.0.0.1/a.flac.'),
      isFalse,
    );
  });

  test('stop 作废在途的打开', () async {
    backend.gates['b'] = Completer<void>();
    await engine.playQueue(_queue(<String>['a', 'b']));
    final Future<void> toB = engine.skipNext();
    await engine.stop();
    backend.gates['b']!.complete();
    await toB;
    expect(engine.isActive, isFalse);
    expect(engine.isPlaying, isFalse);
    expect(engine.resolving, isFalse);
    expect(started, <String>['a']);
  });
}
