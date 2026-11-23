import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_mv_backdrop.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// 设置「有 MV 时背景放 MV」（`music.lyrics_mv_backdrop`）的效果探针：歌词页把偏好原样
/// 交给 [MusicMvBackdropController.enabled]，这里咬住「开 → 订阅当前曲目的画面来源；
/// 关 → 退订、不再找画面；再开 → 重新订阅」。settings_schema_coverage_test 的
/// kCoveredElsewhere 指向本文件。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

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
  }) async {}

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

/// 记录解析器被问了哪些曲目、每条订阅有没有被退掉；画面一律发 null（不建 mpv）。
class _Resolver {
  final List<String> asked = <String>[];
  final List<StreamController<MusicMvBackdropSource?>> streams =
      <StreamController<MusicMvBackdropSource?>>[];
  int cancelled = 0;

  Stream<MusicMvBackdropSource?> call(MusicPlayItem item) {
    asked.add(item.trackUid);
    final StreamController<MusicMvBackdropSource?> c =
        StreamController<MusicMvBackdropSource?>(onCancel: () => cancelled++);
    streams.add(c);
    c.add(null);
    return c.stream;
  }
}

MusicPlayItem _track(String id) => MusicPlayItem(
  trackUid: 'l-$id',
  path: '/m/$id.flac',
  title: id,
  durationMs: 240000,
);

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late MusicPlayerEngine engine;
  late MusicLyricsClock clock;
  late FushiDatabase db;
  late _Resolver resolver;

  setUp(() async {
    backend = _Backend();
    engine = MusicPlayerEngine(backendFactory: () => backend);
    clock = MusicLyricsClock(engine);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    resolver = _Resolver();
    await engine.playQueue(<MusicPlayItem>[_track('a')]);
  });

  tearDown(() async {
    clock.dispose();
    engine.dispose();
    await db.close();
  });

  MusicMvBackdropController make({required bool enabled}) =>
      MusicMvBackdropController(
        engine: engine,
        clock: clock,
        database: db,
        enabled: enabled,
        resolver: resolver.call,
      );

  test('开着：订阅当前曲目的画面来源', () async {
    final MusicMvBackdropController c = make(enabled: true);
    await _drain();
    expect(resolver.asked, <String>['l-a']);
    expect(resolver.cancelled, 0);
    c.dispose();
    expect(resolver.cancelled, 1);
  });

  test('关着：从不找画面、不显示', () async {
    final MusicMvBackdropController c = make(enabled: false);
    await _drain();
    expect(resolver.asked, isEmpty);
    expect(c.showing, isFalse);
    expect(c.source, isNull);
    c.dispose();
  });

  test('关掉即退订，再打开重新订阅当前曲目', () async {
    final MusicMvBackdropController c = make(enabled: true);
    await _drain();
    expect(resolver.asked, <String>['l-a']);

    c.enabled = false;
    await _drain();
    expect(resolver.cancelled, 1);
    expect(resolver.asked, <String>['l-a']);
    expect(c.source, isNull);
    expect(c.showing, isFalse);

    c.enabled = true;
    await _drain();
    expect(resolver.asked, <String>['l-a', 'l-a']);
    expect(resolver.cancelled, 1);
    c.dispose();
    expect(resolver.cancelled, 2);
  });
}
