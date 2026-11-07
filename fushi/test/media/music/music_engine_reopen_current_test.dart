import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginQuality;

/// 只记 openPair（当前 / 下一首 / 播放态 / 起点）的后端替身。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<({String uid, String? next, bool play, Duration startAt})> opens =
      <({String uid, String? next, bool play, Duration startAt})>[];

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
    Duration startAt = Duration.zero,
  }) async => opens.add((
    uid: current.trackUid,
    next: next?.trackUid,
    play: play,
    startAt: startAt,
  ));

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _plugin(String id) => MusicPlayItem(
  trackUid: 'p-$id',
  path: musicPluginTrackPath('demo', id),
  title: id,
  durationMs: 240000,
);

MusicPlayItem _local(String id) => MusicPlayItem(
  trackUid: 'l-$id',
  path: '/m/$id.flac',
  title: id,
  durationMs: 240000,
);

void main() {
  late _Backend backend;
  late MusicPlayerEngine engine;
  final List<String> started = <String>[];

  setUp(() {
    backend = _Backend();
    started.clear();
    engine = MusicPlayerEngine(backendFactory: () => backend, random: Random(1))
      ..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
  });

  tearDown(() => engine.dispose());

  test('插件曲目换音质：原位重开当前 + 下一首，保留进度与播放态，不再记一次开始播放', () async {
    await engine.playQueue(<MusicPlayItem>[_plugin('a'), _plugin('b')]);
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 83), null),
    );
    await engine.reopenCurrent();

    expect(backend.opens, hasLength(2));
    expect(backend.opens.last.uid, 'p-a');
    expect(backend.opens.last.next, 'p-b');
    expect(backend.opens.last.play, isTrue);
    expect(backend.opens.last.startAt, const Duration(seconds: 83));
    expect(engine.position, const Duration(seconds: 83));
    expect(engine.isPlaying, isTrue);
    expect(started, <String>['p-a']);
  });

  test('暂停中换音质：重开后仍是暂停', () async {
    await engine.playQueue(<MusicPlayItem>[_plugin('a')]);
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 12), null),
    );
    await engine.pause();
    await engine.reopenCurrent();

    expect(backend.opens.last.play, isFalse);
    expect(backend.opens.last.startAt, const Duration(seconds: 12));
    expect(engine.isPlaying, isFalse);
  });

  test('本地文件不重开（重开拿到的是同一份样本）', () async {
    await engine.playQueue(<MusicPlayItem>[_local('a')]);
    await engine.reopenCurrent();
    expect(backend.opens, hasLength(1));
  });

  test('不支持起点的后端（托管播放）不重开', () async {
    final _Backend managed = _Backend();
    final MusicPlayerEngine e = MusicPlayerEngine(
      backendFactory: () => managed,
      random: Random(1),
      capabilitiesOf: (MusicPlayItem _) => const MusicBackendCapabilities(
        signalPath: false,
        abLoop: false,
        startAt: false,
      ),
    );
    addTearDown(e.dispose);
    await e.playQueue(<MusicPlayItem>[_plugin('a')]);
    await e.reopenCurrent();
    expect(managed.opens, hasLength(1));
  });

  test('服务器码率上限 → 插件缺省音质档（独立设置之前的旧行为）', () {
    expect(musicPluginQualityForBitrate(0), MusicPluginQuality.lossless);
    expect(musicPluginQualityForBitrate(320), MusicPluginQuality.high);
    expect(musicPluginQualityForBitrate(128), MusicPluginQuality.standard);
  });
}
