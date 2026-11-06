import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_queue_feed.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 记录引擎发给后端的每一条命令；测试手动发后端事件。
class _FakeBackend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  MusicOutputSettings? settings;
  MusicPlayItem? current;
  MusicPlayItem? next;
  bool disposed = false;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {
    settings = s;
    log.add('settings:${s.replayGain.name}:${s.gapless}');
  }

  /// 每次 openPair / replaceNext 带的 crossfadeNext。
  final List<bool> crossfadeFlags = <bool>[];

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    this.current = current;
    this.next = next;
    crossfadeFlags.add(crossfadeNext);
    log.add('open:${current.trackUid}+${next?.trackUid}');
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    this.next = next;
    crossfadeFlags.add(crossfadeNext);
    log.add('next:${next?.trackUid}');
  }

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      log.add('ab:${a?.inMilliseconds}-${b?.inMilliseconds}');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid, {int? durationMs = 200000}) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: durationMs,
);

/// 每次 next() 依次吐出预置的一批，用完回空（= 没有更多）。
class _ScriptedFeed implements MusicQueueFeed {
  _ScriptedFeed(this.batches);

  final List<List<MusicPlayItem>> batches;
  int calls = 0;

  @override
  Future<List<MusicPlayItem>> next() async {
    final int i = calls++;
    return i < batches.length ? batches[i] : const <MusicPlayItem>[];
  }
}

const MusicPlaySource _radio = MusicPlaySource(
  kind: MusicPlaySourceKind.other,
  id: 'radio:test',
);

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeBackend backend;
  late MusicPlayerEngine engine;
  late MusicQueueFeedRunner runner;

  setUp(() {
    backend = _FakeBackend();
    engine = MusicPlayerEngine(
      backendFactory: () => backend,
      random: Random(1),
    );
    runner = MusicQueueFeedRunner(engine);
  });

  tearDown(() {
    runner.dispose();
    engine.dispose();
  });

  test('appendToQueue：当前是最后一首时补上预排的下一首', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a')]);
    expect(backend.log.last, 'open:a+null');
    await engine.appendToQueue(<MusicPlayItem>[_item('b'), _item('c')]);
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'c',
    ]);
    expect(backend.log.last, 'next:b');
    expect(engine.current?.trackUid, 'a', reason: '不打断正在放的');
  });

  test('appendToQueue：最后一首已放完停下时接着放追加的第一首', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a')]);
    backend.controller.add(const MusicBackendCompleted());
    expect(engine.isPlaying, isFalse);
    await engine.appendToQueue(<MusicPlayItem>[_item('b')]);
    expect(engine.current?.trackUid, 'b');
    expect(backend.log.last, 'open:b+null');
  });

  test('电台：首批开播，快到队尾时续取并拼到队尾', () async {
    final _ScriptedFeed feed = _ScriptedFeed(<List<MusicPlayItem>>[
      <MusicPlayItem>[_item('a'), _item('b'), _item('c')],
      <MusicPlayItem>[_item('d'), _item('e')],
    ]);
    expect(await runner.play(feed, source: _radio), isTrue);
    expect(engine.current?.trackUid, 'a');
    expect(feed.calls, 1, reason: '离队尾还远，不提前取');

    backend.controller.add(const MusicBackendAdvanced());
    await _settle();
    expect(engine.current?.trackUid, 'b');
    expect(feed.calls, 2, reason: '只剩 1 首时续取');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'c',
      'd',
      'e',
    ]);
    expect(runner.activeSource, same(_radio));
  });

  test('电台：取到空批 = 没有更多，停止续取', () async {
    final _ScriptedFeed feed = _ScriptedFeed(<List<MusicPlayItem>>[
      <MusicPlayItem>[_item('a'), _item('b')],
    ]);
    await runner.play(feed, source: _radio);
    await _settle();
    expect(feed.calls, 2);
    expect(runner.activeSource, isNull);
    backend.controller.add(const MusicBackendAdvanced());
    await _settle();
    expect(feed.calls, 2, reason: '停了就不再问');
  });

  test('电台：用户换了别的队列即停止续取', () async {
    final _ScriptedFeed feed = _ScriptedFeed(<List<MusicPlayItem>>[
      <MusicPlayItem>[_item('a'), _item('b'), _item('c'), _item('d')],
      <MusicPlayItem>[_item('x')],
    ]);
    await runner.play(feed, source: _radio);
    await engine.playQueue(<MusicPlayItem>[_item('p'), _item('q')]);
    await _settle();
    expect(runner.activeSource, isNull);
    expect(feed.calls, 1);
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'p',
      'q',
    ]);
  });

  test('电台：首批为空不开播、回 false', () async {
    final _ScriptedFeed feed = _ScriptedFeed(const <List<MusicPlayItem>>[]);
    expect(await runner.play(feed, source: _radio), isFalse);
    expect(engine.current, isNull);
    expect(backend.log, isEmpty);
  });
}
