import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_routing_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 记录调用的替身后端；`failOpen` 里的曲目打开时抛 [MusicTrackOpenException]。
class _FakeBackend implements MusicOutputBackend {
  _FakeBackend(this.name);

  final String name;
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  final Set<String> failOpen = <String>{};
  MusicOutputSettings? settings;
  bool disposed = false;

  void emit(MusicBackendEvent e) => controller.add(e);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async => settings = s;

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    log.add('open:${current.trackUid}+${next?.trackUid}:$play:$crossfadeNext');
    if (failOpen.contains(current.trackUid)) {
      throw MusicTrackOpenException(
        MusicBackendFailed(
          'no stream',
          reason: MusicPlaybackFailure.trackUnavailable,
        ),
      );
    }
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => log.add('next:${next?.trackUid}:$crossfadeNext');

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      log.add('loop:${a?.inMilliseconds}-${b?.inMilliseconds}');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async {
    log.add('devices');
    return const <MusicAudioDevice>[];
  }
}

MusicPlayItem _item(String uid) =>
    MusicPlayItem(trackUid: uid, path: uid, title: uid);

/// `am:` 开头的曲目走「托管」路由。
bool _isHosted(MusicPlayItem i) => i.path.startsWith('am:');

const MusicBackendCapabilities _hostedCaps = MusicBackendCapabilities(
  signalPath: false,
  abLoop: false,
);

void main() {
  late _FakeBackend mpv;
  late _FakeBackend hosted;
  late List<MusicBackendRoute> routes;
  late MusicRoutingBackend router;
  late List<MusicBackendEvent> events;

  setUp(() {
    mpv = _FakeBackend('mpv');
    hosted = _FakeBackend('hosted');
    routes = <MusicBackendRoute>[
      MusicBackendRoute(
        id: 'hosted',
        handles: _isHosted,
        create: () => hosted,
        capabilities: _hostedCaps,
      ),
    ];
    router = MusicRoutingBackend(fallback: () => mpv, routes: routes);
    events = <MusicBackendEvent>[];
    router.events.listen(events.add);
  });

  tearDown(() => router.dispose());

  test('没有路由表时原样转发给默认链路', () async {
    final MusicRoutingBackend plain = MusicRoutingBackend(fallback: () => mpv);
    final List<MusicBackendEvent> got = <MusicBackendEvent>[];
    plain.events.listen(got.add);
    await plain.openPair(
      _item('a'),
      _item('b'),
      play: true,
      crossfadeNext: true,
    );
    await plain.replaceNext(_item('c'), crossfadeNext: true);
    await plain.pause();
    await plain.seek(const Duration(seconds: 3));
    await plain.setAbLoop(Duration.zero, const Duration(seconds: 1));
    mpv.emit(const MusicBackendAdvanced('b'));
    mpv.emit(const MusicBackendCompleted());
    await pumpEventQueue();
    expect(mpv.log, <String>[
      'open:a+b:true:true',
      'next:c:true',
      'pause',
      'seek:3000',
      'loop:0-1000',
    ]);
    expect(got.map((MusicBackendEvent e) => e.runtimeType), <Type>[
      MusicBackendAdvanced,
      MusicBackendCompleted,
    ]);
    await plain.dispose();
    expect(mpv.disposed, isTrue);
  });

  test('设置下发给已建与后建的子后端', () async {
    const MusicOutputSettings s = MusicOutputSettings(
      gapless: false,
      replayGain: MusicReplayGainMode.off,
    );
    await router.openPair(_item('a'), null, play: true);
    await router.applySettings(s);
    expect(mpv.settings, s);
    await router.openPair(_item('am:x'), null, play: true);
    await pumpEventQueue();
    expect(hosted.settings, s);
  });

  test('下一首在另一后端：当前后端不预排，播完由路由层接力并补发 Advanced', () async {
    await router.openPair(
      _item('a'),
      _item('am:x'),
      play: true,
      crossfadeNext: true,
    );
    expect(mpv.log, <String>['open:a+null:true:false']);
    expect(router.activeRoute, kMusicDefaultBackendRoute);

    mpv.emit(const MusicBackendCompleted());
    await pumpEventQueue();

    expect(mpv.log.last, 'stop');
    expect(hosted.log, <String>['open:am:x+null:true:false']);
    expect(router.activeRoute, 'hosted');
    expect(events.whereType<MusicBackendCompleted>(), isEmpty);
    expect((events[0] as MusicBackendAdvanced).trackUid, 'am:x');
    expect((events[1] as MusicBackendPlaying).playing, isTrue);

    // 之后的控制落到新后端，旧后端的尾巴事件不再转发。
    await router.pause();
    expect(hosted.log.last, 'pause');
    events.clear();
    mpv.emit(const MusicBackendPosition(Duration(seconds: 9), null));
    hosted.emit(const MusicBackendPosition(Duration(seconds: 1), null));
    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(
      (events.single as MusicBackendPosition).position,
      const Duration(seconds: 1),
    );
  });

  test('接力时下一首打不开：按「预排的下一首失败」上报', () async {
    hosted.failOpen.add('am:x');
    await router.openPair(_item('a'), _item('am:x'), play: true);
    mpv.emit(const MusicBackendCompleted());
    await pumpEventQueue();
    final MusicBackendFailed f = events.single as MusicBackendFailed;
    expect(f.trackUid, 'am:x');
    expect(f.reason, MusicPlaybackFailure.trackUnavailable);
  });

  test('replaceNext 换回同后端 / 清空后，播完照常上报 Completed', () async {
    await router.openPair(_item('a'), _item('am:x'), play: true);
    await router.replaceNext(null);
    mpv.emit(const MusicBackendCompleted());
    await pumpEventQueue();
    expect(events.single, isA<MusicBackendCompleted>());
    expect(hosted.log, isEmpty);

    await router.replaceNext(_item('b'), crossfadeNext: true);
    expect(mpv.log.last, 'next:b:true');
  });

  test('openPair 换到另一后端时先停旧后端', () async {
    await router.openPair(_item('a'), null, play: true);
    await router.openPair(_item('am:x'), _item('am:y'), play: false);
    expect(mpv.log, <String>['open:a+null:true:false', 'stop']);
    expect(hosted.log, <String>['open:am:x+am:y:false:false']);
    // 接回默认链路。
    await router.openPair(_item('b'), null, play: true);
    expect(hosted.log.last, 'stop');
    expect(mpv.log.last, 'open:b+null:true:false');
  });

  test('输出设备只问默认链路', () async {
    await router.openPair(_item('am:x'), null, play: true);
    await router.listAudioDevices();
    expect(mpv.log, <String>['devices']);
  });

  test('能力按曲目所属路由给出', () {
    expect(
      musicBackendCapabilitiesFor(routes, _item('a')),
      MusicBackendCapabilities.full,
    );
    expect(musicBackendCapabilitiesFor(routes, _item('am:x')), _hostedCaps);
  });

  group('接进引擎', () {
    late MusicPlayerEngine engine;

    setUp(() {
      engine = MusicPlayerEngine(
        backendFactory: () =>
            MusicRoutingBackend(fallback: () => mpv, routes: routes),
        capabilitiesOf: (MusicPlayItem i) =>
            musicBackendCapabilitiesFor(routes, i),
      );
    });

    tearDown(() => engine.dispose());

    test('跨后端自然推进：队列前进、能力随当前曲目切换', () async {
      await engine.playQueue(<MusicPlayItem>[
        _item('a'),
        _item('am:x'),
        _item('b'),
      ]);
      expect(engine.capabilities, MusicBackendCapabilities.full);

      mpv.emit(const MusicBackendPosition(Duration(seconds: 1), null));
      mpv.emit(const MusicBackendPlaying(true));
      mpv.emit(const MusicBackendCompleted());
      await pumpEventQueue();

      expect(engine.current?.trackUid, 'am:x');
      expect(engine.isPlaying, isTrue);
      expect(engine.capabilities, _hostedCaps);
      // 引擎在 Advanced 后补发的下一首在默认链路：托管后端不预排。
      expect(hosted.log, <String>[
        'open:am:x+null:true:false',
        'next:null:false',
      ]);

      // 托管后端做不了循环、读不了信号路径。
      await engine.setAbLoop(
        const MusicAbLoop(Duration.zero, Duration(seconds: 2)),
      );
      expect(engine.abLoop, isNull);
      expect(await engine.readSignalPath(), isNull);

      // 再接力回默认链路。
      hosted.emit(const MusicBackendCompleted());
      await pumpEventQueue();
      expect(engine.current?.trackUid, 'b');
      // 接力打开 b，引擎随后补发「队尾没有下一首」。
      expect(mpv.log.sublist(mpv.log.length - 2), <String>[
        'open:b+null:true:false',
        'next:null:false',
      ]);
      expect(engine.capabilities, MusicBackendCapabilities.full);
    });
  });
}
