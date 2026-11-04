import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show appleMusicSongIdFromPath, appleMusicSongUri, isAppleMusicTrackPath;
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;
import 'package:fushi_engine/media/music/apple_music/apple_music_station.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show musicServerTrackUid;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_output_backend.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_station_item.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_routing_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 记录调用、由测试手动推事件的桥。
class _FakeBridge implements AppleMusicBridge {
  final StreamController<AppleMusicPlayerEvent> ctrl =
      StreamController<AppleMusicPlayerEvent>.broadcast(sync: true);
  final List<String> calls = <String>[];
  Exception? playError;

  /// 卡住 playStation（模拟 setQueue 期间页面已发 nowPlaying）。
  Completer<void>? stationGate;

  @override
  Stream<AppleMusicPlayerEvent> get events => ctrl.stream;

  @override
  Future<void> play(
    String songId, {
    int startMs = 0,
    bool autoplay = true,
  }) async {
    calls.add('play:$songId:$autoplay');
    final Exception? e = playError;
    if (e != null) throw e;
  }

  @override
  Future<void> playStation(String stationId, {bool autoplay = true}) async {
    calls.add('station:$stationId:$autoplay');
    await stationGate?.future;
    final Exception? e = playError;
    if (e != null) throw e;
  }

  @override
  Future<void> skipToNext() async => calls.add('skip');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(int positionMs) async => calls.add('seek:$positionMs');
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<AppleMusicAccountState> accountState() async =>
      AppleMusicAccountState.signedOut;
  @override
  Future<AppleMusicAccountState> authorize(BuildContext context) async =>
      AppleMusicAccountState.signedOut;
  @override
  Future<void> unauthorize() async {}
  @override
  Future<AppleMusicUserCredentials?> userCredentials() async => null;
  @override
  Future<void> dispose() async {}
}

/// 自管队列的引擎替身后端：记命令，测试手动推事件。
class _ExternalBackend implements MusicExternalQueueBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];

  /// 卡住 openPair（模拟桥还在 setQueue）。
  Completer<void>? openGate;

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
    log.add('open:${current.trackUid}+${next?.trackUid}');
    await openGate?.future;
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => log.add('next:${next?.trackUid}');
  @override
  Future<void> skipToNext() async => log.add('skip');
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

final MusicPlayItem _station = appleMusicStationPlayItem(
  stationId: 'ra.978194965',
  storefront: 'JP',
  name: 'Artist Station',
  coverUrl: 'https://img/station.jpg',
);

MusicPlayItem _song(String id, {int? durationMs = 180000}) => MusicPlayItem(
  trackUid: appleMusicStationSongTrackUid('jp', id),
  path: appleMusicSongUri(id).toString(),
  title: 'Song $id',
  durationMs: durationMs,
);

MusicPlayItem _local(String uid) =>
    MusicPlayItem(trackUid: uid, path: '/m/$uid.flac', title: uid);

Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('station path', () {
    test('round-trips id and storefront; song paths are not stations', () {
      final Uri u = appleMusicStationUri('ra.978194965', storefront: 'US');
      expect(u.toString(), 'fushi-apple-music://station/ra.978194965?sf=us');
      final String path = u.toString();
      // 与整曲同一 scheme：路由照样落到 MusicKit 后端。
      expect(isAppleMusicTrackPath(path), isTrue);
      expect(isAppleMusicStationPath(path), isTrue);
      expect(appleMusicStationIdFromPath(path), 'ra.978194965');
      expect(appleMusicStationStorefrontFromPath(path), 'us');
      expect(appleMusicSongIdFromPath(path), isNull);

      final String song = appleMusicSongUri('123').toString();
      expect(isAppleMusicStationPath(song), isFalse);
      expect(appleMusicStationIdFromPath(song), isNull);
      expect(appleMusicStationIdFromPath('https://x/station/1'), isNull);
      expect(
        appleMusicStationIdFromPath('fushi-apple-music://station/'),
        isNull,
      );
      // 没带 / 坏的 storefront 落缺省（与 catalog 归一化一致）。
      expect(
        appleMusicStationStorefrontFromPath('fushi-apple-music://station/ra.1'),
        'jp',
      );
    });

    test('song identity matches catalog playback of the same song', () {
      expect(
        appleMusicStationSongTrackUid('JP', '111'),
        musicServerTrackUid('apple-music:jp', '111'),
      );
      expect(appleMusicCatalogServerId('us'), 'apple-music:us');
      expect(
        _station.trackUid,
        appleMusicStationTrackUid('ra.978194965', 'jp'),
      );
      expect(_station.path, 'fushi-apple-music://station/ra.978194965?sf=jp');
      expect(_station.title, 'Artist Station');
      expect(_station.coverPath, 'https://img/station.jpg');
    });

    test(
      'now-playing item: song gets catalog identity, live keeps station',
      () {
        final MusicPlayItem song = appleMusicStationNowPlayingItem(
          _station,
          const AppleMusicNowPlaying(
            songId: '111',
            title: 'S1',
            artist: 'A1',
            album: 'AL1',
            artworkUrl: 'https://x/{w}x{h}bb.jpg',
            durationMs: 180000,
          ),
        );
        expect(song.trackUid, musicServerTrackUid('apple-music:jp', '111'));
        expect(song.path, appleMusicSongUri('111').toString());
        expect(song.title, 'S1');
        expect(song.artist, 'A1');
        expect(song.album, 'AL1');
        expect(song.durationMs, 180000);
        expect(song.coverPath, 'https://x/400x400bb.jpg');

        final MusicPlayItem live = appleMusicStationNowPlayingItem(
          _station,
          const AppleMusicNowPlaying(title: 'Live Show'),
        );
        expect(live.trackUid, _station.trackUid);
        expect(live.path, _station.path);
        expect(live.title, 'Live Show');
        expect(live.durationMs, isNull);
        expect(live.coverPath, _station.coverPath);
      },
    );
  });

  group('bridge event parsing', () {
    test('native nowPlaying', () {
      final AppleMusicNowPlaying np =
          parseAppleMusicNativeEvent(<String, Object?>{
                'type': 'nowPlaying',
                'songId': '5',
                'title': 'T',
                'artist': 'A',
                'album': '',
                'artworkUrl': 'https://a/600x600bb.jpg',
                'durationMs': 1000.6,
              })!
              as AppleMusicNowPlaying;
      expect(np.songId, '5');
      expect(np.title, 'T');
      expect(np.artist, 'A');
      expect(np.album, isNull);
      expect(np.artworkUrl, 'https://a/600x600bb.jpg');
      expect(np.durationMs, 1001);
      final AppleMusicNowPlaying live =
          parseAppleMusicNativeEvent(<String, Object?>{
                'type': 'nowPlaying',
                'title': 'Apple Music 1',
                'durationMs': 0,
              })!
              as AppleMusicNowPlaying;
      expect(live.songId, isNull);
      expect(live.durationMs, isNull);
    });

    test('web nowPlaying, and station ended between songs is not the end', () {
      final ({AppleMusicPlayerEvent? event, int? state}) np =
          parseAppleMusicWebEvent(<String, Object?>{
            'type': 'nowPlaying',
            'songId': '9',
            'title': 'X',
            'durationMs': 2000,
          }, lastState: MusicKitPlaybackState.playing);
      expect(np.event, isA<AppleMusicNowPlaying>());
      expect((np.event! as AppleMusicNowPlaying).songId, '9');
      expect(np.state, MusicKitPlaybackState.playing);

      // 电台：一首放完的 ended 只是换歌过渡。
      final ({AppleMusicPlayerEvent? event, int? state}) between =
          parseAppleMusicWebEvent(
            <String, Object?>{
              'type': 'state',
              'state': MusicKitPlaybackState.ended,
            },
            lastState: MusicKitPlaybackState.playing,
            station: true,
          );
      expect(between.event, isNull);
      expect(between.state, MusicKitPlaybackState.playing);
      // 整个队列 completed 才算结束。
      expect(
        parseAppleMusicWebEvent(
          <String, Object?>{
            'type': 'state',
            'state': MusicKitPlaybackState.completed,
          },
          lastState: MusicKitPlaybackState.playing,
          station: true,
        ).event,
        isA<AppleMusicEnded>(),
      );
      // 单曲照旧：ended 即结束。
      expect(
        parseAppleMusicWebEvent(<String, Object?>{
          'type': 'state',
          'state': MusicKitPlaybackState.ended,
        }, lastState: MusicKitPlaybackState.playing).event,
        isA<AppleMusicEnded>(),
      );
    });
  });

  group('AppleMusicOutputBackend station', () {
    late _FakeBridge bridge;
    late AppleMusicOutputBackend backend;
    late List<MusicBackendEvent> events;

    setUp(() {
      bridge = _FakeBridge();
      backend = AppleMusicOutputBackend(bridge);
      events = <MusicBackendEvent>[];
      backend.events.listen(events.add);
    });
    tearDown(() => backend.dispose());

    test(
      'plays the station and turns now-playing into the engine item',
      () async {
        // 引擎给了「下一首」也不排：电台自管队列。
        await backend.openPair(_station, _local('x'), play: true);
        expect(bridge.calls, <String>['station:ra.978194965:true']);

        bridge.ctrl.add(
          const AppleMusicNowPlaying(
            songId: '111',
            title: 'S1',
            durationMs: 180000,
          ),
        );
        bridge.ctrl.add(
          const AppleMusicProgress(positionMs: 700, songId: '111'),
        );
        await _settle();
        final MusicPlayItem item = events
            .whereType<MusicBackendNowPlayingChanged>()
            .single
            .item;
        expect(item.trackUid, appleMusicStationSongTrackUid('jp', '111'));
        expect(item.title, 'S1');
        final MusicBackendPosition pos = events
            .whereType<MusicBackendPosition>()
            .last;
        expect(pos.position, const Duration(milliseconds: 700));
        expect(pos.duration, const Duration(milliseconds: 180000));

        // 换歌后的失败按新那首对位（与引擎就地换过的当前项一致）。
        bridge.ctrl.add(const AppleMusicPlaybackError('DRM', songId: '111'));
        await _settle();
        expect(
          events.whereType<MusicBackendFailed>().single.trackUid,
          item.trackUid,
        );
      },
    );

    test('ended means the station is over: completes, no next', () async {
      await backend.openPair(_station, _local('x'), play: true);
      bridge.ctrl.add(const AppleMusicEnded());
      await _settle();
      expect(events.whereType<MusicBackendCompleted>(), hasLength(1));
      expect(events.whereType<MusicBackendAdvanced>(), isEmpty);
      expect(bridge.calls, <String>['station:ra.978194965:true']);
    });

    test('skipToNext goes to the bridge only for a station', () async {
      await backend.openPair(_song('1'), null, play: true);
      await backend.skipToNext();
      expect(bridge.calls, <String>['play:1:true'], reason: '单曲不理会');
      // 单曲时桥报的 nowPlaying 不转发。
      bridge.ctrl.add(const AppleMusicNowPlaying(songId: '1', title: 'x'));
      await _settle();
      expect(events.whereType<MusicBackendNowPlayingChanged>(), isEmpty);

      await backend.openPair(_station, null, play: true);
      await backend.skipToNext();
      expect(bridge.calls.last, 'skip');
    });

    test('now-playing reported while the station opens is kept', () async {
      final Completer<void> gate = Completer<void>();
      bridge.stationGate = gate;
      final Future<void> open = backend.openPair(_station, null, play: true);
      await Future<void>.delayed(Duration.zero);
      bridge.ctrl.add(const AppleMusicNowPlaying(songId: '42', title: 'First'));
      gate.complete();
      await open;
      await _settle();
      expect(
        events.whereType<MusicBackendNowPlayingChanged>().single.item.title,
        'First',
      );
    });

    test('a station open superseded by a song drops its now-playing', () async {
      final Completer<void> gate = Completer<void>();
      bridge.stationGate = gate;
      final Future<void> first = backend.openPair(_station, null, play: true);
      await Future<void>.delayed(Duration.zero);
      bridge.stationGate = null;
      final Future<void> second = backend.openPair(
        _song('2'),
        null,
        play: true,
      );
      bridge.ctrl.add(const AppleMusicNowPlaying(songId: '9', title: 'old'));
      gate.complete();
      await first;
      await second;
      await _settle();
      expect(events.whereType<MusicBackendNowPlayingChanged>(), isEmpty);
      expect(bridge.calls.last, 'play:2:true');
    });

    test('route declares external queue for stations only', () {
      final MusicBackendRoute route = appleMusicBackendRoute(_FakeBridge.new);
      final List<MusicBackendRoute> routes = <MusicBackendRoute>[route];
      expect(route.handles(_station), isTrue);
      expect(
        musicBackendCapabilitiesFor(routes, _station),
        kAppleMusicStationCapabilities,
      );
      expect(kAppleMusicStationCapabilities.externalQueue, isTrue);
      expect(
        musicBackendCapabilitiesFor(routes, _song('1')).externalQueue,
        isFalse,
      );
    });
  });

  group('engine external queue', () {
    late _ExternalBackend backend;
    late MusicPlayerEngine engine;
    late List<String> started;

    MusicBackendCapabilities caps(MusicPlayItem i) =>
        isAppleMusicStationPath(i.path)
        ? kAppleMusicStationCapabilities
        : MusicBackendCapabilities.full;

    setUp(() {
      backend = _ExternalBackend();
      started = <String>[];
      engine = MusicPlayerEngine(
        backendFactory: () => backend,
        capabilitiesOf: caps,
      )..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
    });
    tearDown(() => engine.dispose());

    test(
      'now-playing replaces the current slot and starts the track',
      () async {
        await engine.playQueue(<MusicPlayItem>[_station, _local('b')]);
        // 不预排 Fushi 的下一首；电台本身不记「开始播」。
        expect(backend.log, <String>['open:${_station.trackUid}+null']);
        expect(engine.next, isNull);
        expect(engine.externalQueue, isTrue);
        expect(started, isEmpty);

        backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
        await _settle();
        expect(engine.index, 0);
        expect(engine.current?.trackUid, _song('1').trackUid);
        expect(engine.queue.first.trackUid, _song('1').trackUid);
        expect(engine.duration, const Duration(milliseconds: 180000));
        expect(engine.position, Duration.zero);
        expect(started, <String>[_song('1').trackUid]);
        // 能力仍按电台判。
        expect(engine.externalQueue, isTrue);
        expect(engine.externalQueueSource?.trackUid, _station.trackUid);
        expect(engine.canSkipPrevious, isFalse);
        expect(engine.canShuffleOrRepeat, isFalse);
        expect(engine.canSeek, isTrue);

        backend.controller.add(MusicBackendNowPlayingChanged(_song('2')));
        await _settle();
        expect(engine.current?.trackUid, _song('2').trackUid);
        expect(started, <String>[_song('1').trackUid, _song('2').trackUid]);
      },
    );

    test(
      'next delegates to the backend; previous / shuffle do nothing',
      () async {
        await engine.playQueue(<MusicPlayItem>[_station, _local('b')]);
        backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
        await _settle();
        backend.log.clear();

        await engine.skipNext();
        expect(backend.log, <String>['skip']);
        expect(engine.index, 0, reason: 'Fushi 队列不动');

        await engine.skipPrevious();
        await engine.setShuffle(true);
        expect(engine.shuffled, isFalse);
        await engine.setRepeatMode(MusicRepeatMode.all);
        expect(engine.next, isNull);
        expect(backend.log, <String>['skip', 'next:null']);
        expect(engine.current?.trackUid, _song('1').trackUid);
      },
    );

    test('live station (no duration) cannot seek; songs can', () async {
      await engine.playQueue(<MusicPlayItem>[_station]);
      backend.controller.add(
        MusicBackendNowPlayingChanged(
          MusicPlayItem(
            trackUid: _station.trackUid,
            path: _station.path,
            title: 'Live Show',
          ),
        ),
      );
      await _settle();
      // 同一身份只是元数据变了：刷新显示，但这是打开后的第一条，算开始播。
      expect(engine.current?.title, 'Live Show');
      expect(started, <String>[_station.trackUid]);
      expect(engine.canSeek, isFalse);
      backend.log.clear();
      await engine.seek(const Duration(seconds: 10));
      expect(backend.log, isEmpty);

      backend.controller.add(
        MusicBackendNowPlayingChanged(
          MusicPlayItem(
            trackUid: _station.trackUid,
            path: _station.path,
            title: 'Next Show',
          ),
        ),
      );
      await _settle();
      expect(engine.current?.title, 'Next Show');
      expect(started, hasLength(1), reason: '同一身份不重复记开始播');

      backend.controller.add(MusicBackendNowPlayingChanged(_song('3')));
      await _settle();
      expect(engine.canSeek, isTrue);
      await engine.seek(const Duration(seconds: 10));
      expect(backend.log, <String>['seek:10000']);
    });

    test('after a failure, play reopens the station, not the song', () async {
      await engine.playQueue(<MusicPlayItem>[_station]);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
      await _settle();
      backend.controller.add(
        MusicBackendFailed(
          'lost',
          reason: MusicPlaybackFailure.appleMusicSessionLost,
          trackUid: _song('1').trackUid,
        ),
      );
      await _settle();
      expect(engine.isPlaying, isFalse);
      backend.log.clear();
      await engine.play();
      expect(backend.log, <String>['open:${_station.trackUid}+null']);
      expect(engine.current?.trackUid, _station.trackUid);
      expect(engine.externalQueue, isTrue);
    });

    test('jumping away restores the station slot', () async {
      await engine.playQueue(<MusicPlayItem>[_station, _local('b')]);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
      await _settle();
      await engine.jumpTo(1);
      expect(engine.current?.trackUid, 'b');
      expect(engine.externalQueue, isFalse);
      expect(engine.queue.first.trackUid, _station.trackUid);
      expect(engine.canSkipPrevious, isTrue);
    });

    test('a new queue after a station plays the new queue as given', () async {
      await engine.playQueue(<MusicPlayItem>[_station]);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
      await _settle();
      backend.log.clear();

      await engine.playQueue(<MusicPlayItem>[
        _local('a'),
        _local('b'),
        _local('c'),
      ]);
      expect(backend.log, <String>['open:a+b']);
      expect(engine.current?.trackUid, 'a');
      expect(engine.externalQueue, isFalse);
      expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
        'a',
        'b',
        'c',
      ]);
      expect(engine.externalQueueSource, isNull);
    });

    test('a second station replaces the first, not the reverse', () async {
      final MusicPlayItem station2 = appleMusicStationPlayItem(
        stationId: 'ra.1000000001',
        storefront: 'JP',
        name: 'Other Station',
        coverUrl: 'https://img/station2.jpg',
      );
      await engine.playQueue(<MusicPlayItem>[_station, _local('x')]);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
      await _settle();
      backend.log.clear();

      await engine.playQueue(<MusicPlayItem>[station2]);
      expect(backend.log, <String>['open:${station2.trackUid}+null']);
      expect(engine.current?.trackUid, station2.trackUid);
      expect(engine.queue.single.trackUid, station2.trackUid);

      backend.controller.add(MusicBackendNowPlayingChanged(_song('9')));
      await _settle();
      expect(engine.externalQueueSource?.trackUid, station2.trackUid);
    });

    test('now-playing reported while opening is applied after open', () async {
      final Completer<void> gate = Completer<void>();
      backend.openGate = gate;
      final Future<void> open = engine.playQueue(<MusicPlayItem>[_station]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.resolving, isTrue);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('7')));
      gate.complete();
      await open;
      await _settle();
      expect(engine.current?.trackUid, _song('7').trackUid);
      expect(started, <String>[_song('7').trackUid]);
    });

    test('non-external queues ignore now-playing events', () async {
      await engine.playQueue(<MusicPlayItem>[_local('a'), _local('b')]);
      backend.controller.add(MusicBackendNowPlayingChanged(_song('1')));
      await _settle();
      expect(engine.current?.trackUid, 'a');
      await engine.skipNext();
      expect(engine.current?.trackUid, 'b');
      expect(backend.log, isNot(contains('skip')));
    });
  });

  test(
    'engine over the real Apple Music backend plays a station end to end',
    () async {
      final _FakeBridge bridge = _FakeBridge();
      final List<String> started = <String>[];
      final MusicPlayerEngine engine = MusicPlayerEngine(
        backendFactory: () => MusicRoutingBackend(
          routes: <MusicBackendRoute>[appleMusicBackendRoute(() => bridge)],
          fallback: _ExternalBackend.new,
        ),
        capabilitiesOf: (MusicPlayItem i) => musicBackendCapabilitiesFor(
          <MusicBackendRoute>[appleMusicBackendRoute(() => bridge)],
          i,
        ),
      )..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
      addTearDown(engine.dispose);

      await engine.playQueue(<MusicPlayItem>[_station]);
      await _settle();
      expect(bridge.calls, <String>['station:ra.978194965:true']);
      bridge.ctrl.add(
        const AppleMusicNowPlaying(
          songId: '111',
          title: 'S1',
          durationMs: 1000,
        ),
      );
      await _settle();
      expect(engine.current?.title, 'S1');
      expect(started, <String>[appleMusicStationSongTrackUid('jp', '111')]);

      await engine.skipNext();
      await _settle();
      expect(bridge.calls.last, 'skip');
      bridge.ctrl.add(const AppleMusicNowPlaying(songId: '222', title: 'S2'));
      await _settle();
      expect(engine.current?.title, 'S2');
      expect(engine.index, 0);
      expect(started, hasLength(2));
    },
  );
}
