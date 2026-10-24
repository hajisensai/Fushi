import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

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

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
  }) async {
    this.current = current;
    this.next = next;
    log.add('open:${current.trackUid}+${next?.trackUid}');
  }

  @override
  Future<void> replaceNext(MusicPlayItem? next) async {
    this.next = next;
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
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

MusicPlayItem _item(String uid, {int? durationMs = 200000}) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: durationMs,
);

void main() {
  late _FakeBackend backend;
  late MusicPlayerEngine engine;
  final List<String> started = <String>[];

  setUp(() {
    backend = _FakeBackend();
    started.clear();
    engine = MusicPlayerEngine(backendFactory: () => backend, random: Random(1))
      ..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
  });

  tearDown(() => engine.dispose());

  test('后端只持有「当前 + 下一首」；无缝推进后引擎补新的下一首', () async {
    await engine.playQueue(<MusicPlayItem>[
      _item('a'),
      _item('b'),
      _item('c'),
    ], context: MusicQueueContext.album);
    expect(backend.log, <String>['settings:album:true', 'open:a+b']);
    expect(engine.current?.trackUid, 'a');
    expect(engine.isPlaying, isTrue);

    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    expect(engine.current?.trackUid, 'b');
    expect(backend.log.last, 'next:c');

    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    expect(engine.current?.trackUid, 'c');
    expect(backend.log.last, 'next:null', reason: '最后一首后面没有可预排的');
    expect(started, <String>['a', 'b', 'c']);

    backend.controller.add(const MusicBackendCompleted());
    expect(engine.isPlaying, isFalse);
  });

  test('ReplayGain：专辑顺序播 album，随机 / 混排 track，关掉 off', () {
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.album,
        shuffled: false,
      ),
      MusicReplayGainMode.album,
    );
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.album,
        shuffled: true,
      ),
      MusicReplayGainMode.track,
    );
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.mixed,
        shuffled: false,
      ),
      MusicReplayGainMode.track,
    );
    expect(
      musicReplayGainModeFor(
        enabled: false,
        context: MusicQueueContext.album,
        shuffled: false,
      ),
      MusicReplayGainMode.off,
    );
  });

  test('随机播放：选中的那首排第一；中途开关随机不打断当前曲目', () async {
    final List<MusicPlayItem> items = <MusicPlayItem>[
      for (final String u in <String>['a', 'b', 'c', 'd', 'e']) _item(u),
    ];
    await engine.playQueue(
      items,
      startIndex: 2,
      context: MusicQueueContext.album,
      shuffle: true,
    );
    expect(engine.current?.trackUid, 'c');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid).toSet(), <String>{
      'a',
      'b',
      'c',
      'd',
      'e',
    });
    expect(backend.settings?.replayGain, MusicReplayGainMode.track);

    await engine.setShuffle(false);
    expect(engine.current?.trackUid, 'c');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'c',
      'd',
      'e',
    ]);
    expect(backend.next?.trackUid, 'd');
    expect(backend.settings?.replayGain, MusicReplayGainMode.album);
    expect(
      backend.log.where((String l) => l.startsWith('open:')),
      hasLength(1),
      reason: '开关随机只换下一首，不重开当前曲目',
    );
  });

  test('上一首：播过 3 秒回到本曲开头，否则退到上一首', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    await engine.skipNext();
    expect(engine.current?.trackUid, 'b');
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 10), null),
    );
    await engine.skipPrevious();
    expect(engine.current?.trackUid, 'b');
    expect(backend.log.last, 'seek:0');
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 1), null),
    );
    await engine.skipPrevious();
    expect(engine.current?.trackUid, 'a');
  });

  test('seek 夹在 [0, 时长]；stop 释放后端', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a', durationMs: 1000)]);
    await engine.seekRelative(const Duration(seconds: -5));
    expect(backend.log.last, 'seek:0');
    await engine.seek(const Duration(seconds: 9));
    expect(backend.log.last, 'seek:1000');
    await engine.stop();
    expect(backend.disposed, isTrue);
    expect(engine.isActive, isFalse);
  });

  test('mpv 映射：CUE 起止成逐文件选项；设置成 gapless / replaygain 属性', () {
    final media = musicMediaOf(
      const MusicPlayItem(
        trackUid: 'x',
        path: '/m/full.flac',
        title: 'x',
        startMs: 1000,
        endMs: 2000,
      ),
    );
    expect(media.start, const Duration(seconds: 1));
    expect(media.end, const Duration(seconds: 2));
    expect(
      musicMpvProperties(
        const MusicOutputSettings(
          gapless: true,
          replayGain: MusicReplayGainMode.album,
        ),
      ),
      containsPair('gapless-audio', 'weak'),
    );
    final Map<String, String> off = musicMpvProperties(
      const MusicOutputSettings(
        gapless: false,
        replayGain: MusicReplayGainMode.off,
      ),
    );
    expect(off['gapless-audio'], 'no');
    expect(off['prefetch-playlist'], 'no');
    expect(off['replaygain'], 'no');
    expect(off['replaygain-clip'], 'no');
  });
}
