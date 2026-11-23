import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show MusicServerBinding;
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_favorites.dart';
import 'package:fushi/src/media/music/server/music_server_loudness_measurer.dart';
import 'package:fushi/src/media/music/server/music_server_loudness_resolver.dart';
import 'package:fushi/src/media/music/server/music_server_offline_queue.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/media/music/server/music_server_playback_reporter.dart'
    show musicServerReportUnreachable;
import 'package:fushi/src/media/music/server/music_server_track_ref.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';

/// 能补记播放、能收藏、能报响度的服务器替身。
class _Server extends Fake
    implements
        MusicServerBrowser,
        MusicServerPlayMarking,
        MusicServerFavoriteEditing,
        MusicServerLoudnessLookup {
  _Server(this.serverId, {this.kind = MusicServerKind.jellyfin});

  @override
  final String serverId;
  @override
  final MusicServerKind kind;
  @override
  bool get countsPlayOnStart => kind == MusicServerKind.jellyfin;

  final List<String> calls = <String>[];

  /// 下一次请求抛的错（null = 成功）。
  Exception? failWith;

  /// 只对这首抛（null = 都抛）。
  String? failOnly;

  MusicServerLoudness? loudness;

  void _maybeFail(String id) {
    final Exception? e = failWith;
    if (e != null && (failOnly == null || failOnly == id)) throw e;
  }

  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async {
    _maybeFail(trackId);
    calls.add('played $trackId ${playedAt.toUtc().toIso8601String()}');
  }

  @override
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) async {
    _maybeFail(id);
    calls.add('fav $id $favorite');
  }

  @override
  Future<bool?> trackFavorite(String trackId) async {
    _maybeFail(trackId);
    return false;
  }

  @override
  Future<MusicServerLoudness?> loudnessOf(MusicServerTrackRef track) async {
    _maybeFail(track.trackId);
    return loudness;
  }
}

class _Rejected implements Exception {
  const _Rejected();
}

void main() {
  late FushiDatabase db;
  late MusicServerOfflineQueue queue;
  late int now;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    now = 1000;
    queue = MusicServerOfflineQueue(clock: () => now);
  });

  tearDown(() async {
    queue.dispose();
    musicServerUnreachable = musicServerReportUnreachable;
    await db.close();
  });

  MusicServerTrackRef ref(String id, {String server = 'jf'}) =>
      MusicServerTrackRef(
        kind: MusicServerKind.jellyfin,
        serverId: server,
        trackId: id,
      );

  group('补发队列', () {
    test('配回服务器后按原时刻、从旧到新补记播放；送达的删掉', () async {
      final _Server jf = _Server('jf');
      queue.attach(db, browsers: () async => <MusicServerBrowser>[jf]);
      final int t1 = DateTime.utc(2026, 11, 20, 10).millisecondsSinceEpoch;
      final int t2 = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;
      await queue.enqueuePlay(ref('b'), playedAtMs: t2);
      await queue.enqueuePlay(ref('a'), playedAtMs: t1);
      await queue.enqueuePlay(ref('a'), playedAtMs: t1);
      await queue.flushAll();
      expect(jf.calls, <String>[
        'played a 2026-11-20T10:00:00.000Z',
        'played b 2026-11-21T10:00:00.000Z',
      ]);
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('仍连不上：这一轮停下、条目全留着', () async {
      final _Server jf = _Server('jf')
        ..failWith = const SocketException('down');
      queue.attach(db, browsers: () async => <MusicServerBrowser>[jf]);
      await queue.enqueuePlay(ref('a'), playedAtMs: 1);
      await queue.enqueuePlay(ref('b'), playedAtMs: 2);
      await queue.flushServer(jf);
      expect(jf.calls, isEmpty);
      final List<MusicServerPendingActionRow> rows = await db
          .listMusicServerPendingActions();
      expect(rows, hasLength(2));
      expect(
        rows.every((MusicServerPendingActionRow r) => r.attempts == 0),
        isTrue,
      );
    });

    test('服务器拒绝（不是连不上）：记尝试次数，到上限丢；别的条目照发', () async {
      final _Server jf = _Server('jf')
        ..failWith = const _Rejected()
        ..failOnly = 'gone';
      queue.attach(db, browsers: () async => <MusicServerBrowser>[jf]);
      await queue.enqueuePlay(ref('gone'), playedAtMs: 1);
      await queue.enqueuePlay(ref('ok'), playedAtMs: 2);
      await queue.flushServer(jf);
      expect(jf.calls, <String>['played ok 1970-01-01T00:00:00.002Z']);
      expect((await db.listMusicServerPendingActions()).single.attempts, 1);
      for (int i = 1; i < kMusicServerPendingMaxAttempts; i++) {
        await queue.flushServer(jf);
      }
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('收藏补发：最后一次切换生效、记成最后已知状态、回调确认', () async {
      final _Server jf = _Server('jf');
      final List<String> applied = <String>[];
      queue
        ..attach(db, browsers: () async => <MusicServerBrowser>[jf])
        ..onFavoriteApplied = (String s, String id, bool fav) =>
            applied.add('$s $id $fav');
      await queue.enqueueFavorite(
        kind: MusicServerKind.jellyfin,
        serverId: 'jf',
        itemId: 'x',
        favorite: true,
      );
      await queue.enqueueFavorite(
        kind: MusicServerKind.jellyfin,
        serverId: 'jf',
        itemId: 'x',
        favorite: false,
      );
      expect(queue.pendingFavorite(musicServerTrackUid('jf', 'x')), isFalse);
      await queue.flushAll();
      expect(jf.calls, <String>['fav x false']);
      expect(applied, <String>['jf x false']);
      expect(
        await queue.lastKnownFavorite(musicServerTrackUid('jf', 'x')),
        isFalse,
      );
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('flushAll 按配置修剪：没配回来的服务器只在过了 TTL 后丢', () async {
      queue.attach(db, browsers: () async => <MusicServerBrowser>[]);
      await queue.enqueuePlay(ref('a', server: 'gone'), playedAtMs: 1);
      await queue.flushAll();
      expect(await db.listMusicServerPendingActions(), hasLength(1));
      now += kMusicServerPendingOrphanTtl.inMilliseconds + 1;
      await queue.flushAll();
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('种类不对的服务器（同一身份换了协议）不发', () async {
      final _Server ss = _Server('jf', kind: MusicServerKind.subsonic);
      queue.attach(db, browsers: () async => <MusicServerBrowser>[ss]);
      await queue.enqueuePlay(ref('a'), playedAtMs: 1);
      await queue.flushServer(ss);
      expect(ss.calls, isEmpty);
      expect(await db.listMusicServerPendingActions(), hasLength(1));
    });
  });

  group('「正在播放」的服务器收藏', () {
    MusicPlayItem item(String id) => MusicPlayItem(
      trackUid: musicServerTrackUid('jf', id),
      path: 'C:/music/$id.flac',
      title: id,
      serverTrack: ref(id),
    );

    test('这台设备上没配那台服务器：切换入队、心形按切换后的值；配回后补发', () async {
      final _Server jf = _Server('jf');
      List<MusicServerBrowser> configured = <MusicServerBrowser>[];
      queue.attach(db, browsers: () async => configured);
      final MusicServerFavoriteStore store = MusicServerFavoriteStore(
        offline: queue,
      );
      final MusicServerTrackFavorites favs = MusicServerTrackFavorites(
        resolve: (MusicPlayItem i) async => musicServerResolveTrack(
          trackUid: i.trackUid,
          path: i.path,
          serverTrack: i.serverTrack,
          browsers: configured,
          localCopies: (_) => null,
        ),
        store: store,
      );
      addTearDown(favs.dispose);
      final MusicPlayItem a = item('a');
      expect(favs.canFavorite(a), isTrue);
      expect(favs.isFavorite(a), isFalse);
      await favs.toggle(a);
      expect(favs.isFavorite(a), isTrue);
      expect(
        (await db.listMusicServerPendingActions()).single.favorite,
        isTrue,
      );

      configured = <MusicServerBrowser>[jf];
      await queue.flushAll();
      expect(jf.calls, <String>['fav a true']);
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('服务器连不上：不还原、不抛，入队', () async {
      final _Server jf = _Server('jf')
        ..failWith = const SocketException('down');
      queue.attach(db, browsers: () async => <MusicServerBrowser>[jf]);
      final MusicServerFavoriteStore store = MusicServerFavoriteStore(
        offline: queue,
      );
      await store.setFavorite(
        jf,
        MusicServerItemKind.track,
        'z',
        favorite: true,
      );
      expect(store.isFavoriteOn('jf', MusicServerItemKind.track, 'z'), isTrue);
      expect((await db.listMusicServerPendingActions()).single.itemId, 'z');
    });

    test('服务器别的错：照旧还原并抛', () async {
      final _Server jf = _Server('jf')..failWith = const _Rejected();
      queue.attach(db, browsers: () async => <MusicServerBrowser>[jf]);
      final MusicServerFavoriteStore store = MusicServerFavoriteStore(
        offline: queue,
      );
      await expectLater(
        store.setFavorite(jf, MusicServerItemKind.track, 'z', favorite: true),
        throwsA(isA<_Rejected>()),
      );
      expect(store.isFavoriteOn('jf', MusicServerItemKind.track, 'z'), isFalse);
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('离线时心形按本机记下的最后已知状态显示', () async {
      queue.attach(db, browsers: () async => <MusicServerBrowser>[]);
      await queue.rememberFavorite(
        kind: MusicServerKind.jellyfin,
        serverId: 'jf',
        itemId: 'k',
        favorite: true,
      );
      final MusicServerTrackFavorites favs = MusicServerTrackFavorites(
        resolve: (MusicPlayItem _) async => null,
        store: MusicServerFavoriteStore(offline: queue),
      );
      addTearDown(favs.dispose);
      final MusicPlayItem k = item('k');
      expect(favs.isFavorite(k), isFalse);
      for (int i = 0; i < 20 && !favs.isFavorite(k); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(favs.isFavorite(k), isTrue);
    });
  });

  group('服务器没给响度：客户端测量', () {
    MusicServerBinding bind(MusicServerBrowser b) => MusicServerBinding(b);

    test('补查：服务器有曲目增益用服务器的；没有用测量值；没配服务器也用测量值', () async {
      final _Server jf = _Server('jf');
      Map<String, MusicServerBinding> bound = <String, MusicServerBinding>{
        'jf': bind(jf),
      };
      final BindingMusicServerLoudnessResolver r =
          BindingMusicServerLoudnessResolver(
            () async => bound,
            measured: (MusicServerTrackRef ref) => musicServerMeasuredLoudness(
              ref,
              db: db,
              localCopies: (_) => null,
            ),
          );
      await db.writeMusicServerTrackMeasuredLoudness(
        trackUid: musicServerTrackUid('jf', 'm'),
        serverKind: 'jellyfin',
        serverId: 'jf',
        itemId: 'm',
        gain: -5,
        peak: 0.7,
        at: 1,
      );
      expect((await r.resolve(ref('m')))?.trackGainDb, -5);
      expect((await r.serverLoudness(ref('m'))).reached, isTrue);

      jf.loudness = const MusicServerLoudness(trackGainDb: -2);
      final BindingMusicServerLoudnessResolver fresh =
          BindingMusicServerLoudnessResolver(
            () async => bound,
            measured: (MusicServerTrackRef ref) => musicServerMeasuredLoudness(
              ref,
              db: db,
              localCopies: (_) => null,
            ),
          );
      expect((await fresh.resolve(ref('m')))?.trackGainDb, -2);

      bound = <String, MusicServerBinding>{};
      final BindingMusicServerLoudnessResolver gone =
          BindingMusicServerLoudnessResolver(
            () async => bound,
            measured: (MusicServerTrackRef ref) => musicServerMeasuredLoudness(
              ref,
              db: db,
              localCopies: (_) => null,
            ),
          );
      expect((await gone.resolve(ref('m')))?.trackGainDb, -5);
      expect((await gone.serverLoudness(ref('m'))).reached, isFalse);
    });

    MusicLoudnessOutcome outcome(double lufs) => (
      measurement: MusicLoudnessMeasurement(
        integratedLufs: lufs,
        truePeakDbtp: -1,
      ),
      failed: false,
      returnCode: 0,
    );

    test('串流曲目播过之后测一次服务器流（服务器答复了且没有值），存进 v176 表', () async {
      final _Server jf = _Server('jf');
      final List<String> inputs = <String>[];
      final BindingMusicServerLoudnessResolver r =
          BindingMusicServerLoudnessResolver(
            () async => <String, MusicServerBinding>{'jf': bind(jf)},
          );
      final MusicServerLoudnessMeasurer m = MusicServerLoudnessMeasurer(
        database: () => db,
        serverLoudness: r.serverLoudness,
        enabled: () => true,
        localCopies: (_) => null,
        measure: (String input) async {
          inputs.add(input);
          return outcome(-11);
        },
        clock: () => 77,
      );
      final MusicPlayItem streamed = MusicPlayItem(
        trackUid: musicServerTrackUid('jf', 's'),
        path: 'http://jf/Audio/s/universal?api_key=SECRET',
        title: 's',
        serverTrack: ref('s'),
      );
      // 没听够：不测。
      m.trackLeft(
        MusicTrackLeave(
          item: streamed,
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 4),
          restoring: false,
        ),
      );
      await m.idle;
      expect(inputs, isEmpty);
      m.trackLeft(
        MusicTrackLeave(
          item: streamed,
          position: const Duration(seconds: 40),
          duration: const Duration(minutes: 4),
          restoring: false,
        ),
      );
      await m.idle;
      expect(inputs, <String>[streamed.path]);
      final MusicServerTrackStateRow row = (await db.getMusicServerTrackState(
        streamed.trackUid,
      ))!;
      expect(row.measuredTrackGain, closeTo(-7, 1e-9));
      expect(row.loudnessMeasuredAt, 77);
      // 表里没有地址 / 凭据。
      expect('${row.toJson()}', isNot(contains('SECRET')));
      // 同一首本进程不再测。
      m.trackPlayed(streamed);
      await m.idle;
      expect(inputs, hasLength(1));
    });

    test('服务器有值 / 服务器没答复 / 播放项自带服务器增益：都不测', () async {
      final _Server jf = _Server('jf')
        ..loudness = const MusicServerLoudness(trackGainDb: -1);
      final List<String> inputs = <String>[];
      Map<String, MusicServerBinding> bound = <String, MusicServerBinding>{
        'jf': bind(jf),
      };
      MusicServerLoudnessMeasurer build() => MusicServerLoudnessMeasurer(
        database: () => db,
        serverLoudness: BindingMusicServerLoudnessResolver(
          () async => bound,
        ).serverLoudness,
        enabled: () => true,
        localCopies: (_) => null,
        measure: (String input) async {
          inputs.add(input);
          return outcome(-11);
        },
      );
      MusicPlayItem streamed(String id, {double? gain}) => MusicPlayItem(
        trackUid: musicServerTrackUid('jf', id),
        path: 'http://jf/Audio/$id',
        title: id,
        rgTrackGain: gain,
        serverTrack: ref(id),
      );
      final MusicServerLoudnessMeasurer m = build()
        ..trackPlayed(streamed('a'))
        ..trackPlayed(streamed('b', gain: -3));
      await m.idle;
      bound = <String, MusicServerBinding>{};
      final MusicServerLoudnessMeasurer offline = build()
        ..trackPlayed(streamed('c'));
      await offline.idle;
      expect(inputs, isEmpty);
    });

    test('离线副本：测本机文件，存进 sidecar 的 measured；测过的不再测', () async {
      final Directory dir = await Directory.systemTemp.createTemp('musmeas');
      addTearDown(() => dir.delete(recursive: true));
      final String path = '${dir.path}/a.flac';
      await File(path).writeAsBytes(<int>[1, 2, 3]);
      final MusicServerLocalCopy copy = (
        path: path,
        coverPath: null,
        codec: 'flac',
        serverId: 'jf',
        trackId: 'a',
        serverKind: MusicServerKind.jellyfin,
        loudness: null,
        measuredLoudness: null,
      );
      final List<String> inputs = <String>[];
      final MusicServerDownloadIndex index = MusicServerDownloadIndex();
      addTearDown(index.dispose);
      final MusicServerLoudnessMeasurer m = MusicServerLoudnessMeasurer(
        database: () => db,
        serverLoudness: (_) async => (reached: false, loudness: null),
        enabled: () => true,
        localCopies: (String uid) =>
            uid == musicServerTrackUid('jf', 'a') ? copy : null,
        index: index,
        measure: (String input) async {
          inputs.add(input);
          return outcome(-14);
        },
        clock: () => 9,
      );
      // 播放项就是 musicServerLocalPlayItem 的产物：带服务器身份（种类取副本行）。
      final MusicPlayItem played = musicServerLocalPlayItem(
        musicServerTrackUid('jf', 'a'),
        copy,
        const MusicServerTrack(id: 'a', title: 'a'),
      );
      expect(played.serverTrack?.kind, MusicServerKind.jellyfin);
      m.trackPlayed(played);
      await m.idle;
      expect(inputs, <String>[path]);
      final MusicServerDownloadSidecar? sidecar =
          await readMusicServerDownloadLoudness(path);
      expect(sidecar?.measured?.trackGainDb, closeTo(-4, 1e-9));
      expect(sidecar?.server, isNull);
      expect(await musicServerDownloadLoudnessMeasured(path), isTrue);

      // 新进程（新测量器）：sidecar 已有测量，不再测。
      final MusicServerLoudnessMeasurer again = MusicServerLoudnessMeasurer(
        database: () => db,
        serverLoudness: (_) async => (reached: false, loudness: null),
        enabled: () => true,
        localCopies: (String uid) => copy,
        index: index,
        measure: (String input) async {
          inputs.add(input);
          return outcome(-14);
        },
      )..trackPlayed(played);
      await again.idle;
      expect(inputs, hasLength(1));

      // 服务器后来给了值：sidecar 顶层是服务器的，测量值留着但播放时服务器优先。
      await writeMusicServerDownloadLoudness(
        path,
        const MusicServerLoudness(trackGainDb: -2),
      );
      final MusicServerDownloadSidecar? both =
          await readMusicServerDownloadLoudness(path);
      expect(both?.server?.trackGainDb, -2);
      expect(both?.measured?.trackGainDb, closeTo(-4, 1e-9));
    });
  });
}
