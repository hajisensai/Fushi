// Jellyfin 服务器曲目在离线 / 服务器配置删了时的播放上报与收藏（v176 离线补发队列）、以及
// 服务器没开 LUFS 扫描时的客户端响度后备，对真服务器的端到端取证：
//
//   A. 客户端经一个本进程里的 TCP 转发口连 Jellyfin（服务器配置里的地址就是这个口）：
//      1. 把 スピーチ 1 / スピーチ 2 下成离线副本（服务器没有 NormalizationGain → 下完对本机文件测
//         响度，sidecar 的 measured 有值）；
//      2. 关掉转发口（客户端指向的地址连不上）：放 スピーチ 1 的离线副本听够门槛 → 播放进队列；
//         「正在播放」点收藏 → 收藏进队列、心形保持切换后的值；
//      3. 删掉服务器配置：放 スピーチ 2 的离线副本（播放项仍带服务器身份）→ 播放进队列；
//      4. 转发口重开、配置加回（同一个地址 = 同一台服务器身份）→ 补发（与 app 启动同一个
//         flushAll）：服务器上两首的 PlayCount 各 +1、LastPlayedDate = 原来的开播时刻（到秒），
//         スピーチ 1 已收藏，队列清空。
//   B. 响度后备：离线副本按 sidecar 的测量值施加增益（mpv volume-gain）；串流的 スピーチ 3 播过
//      一次后在后台从服务器流测一次、落 v176 表，再播时按测量值施加。
//
// 凭据经 --dart-define 注入：FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER / FUSHI_JELLYFIN_PASS。
// 证据是 [srv-offline] 日志行与截图。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_offline_queue.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/music/music_server_collection_actions.dart'
    show musicServerDownloadServiceOf;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_JELLYFIN_URL');
const String _username = String.fromEnvironment('FUSHI_JELLYFIN_USER');
const String _password = String.fromEnvironment('FUSHI_JELLYFIN_PASS');
const String _albumName = '日本語スピーチ';

/// 本进程里的 TCP 转发口：开着 = 客户端连得上服务器，关掉 = 客户端指向的地址是死的。
class _Relay {
  _Relay(this.upstream);

  final Uri upstream;
  ServerSocket? _server;
  final List<Socket> _open = <Socket>[];
  int port = 0;

  Future<void> start() async {
    final ServerSocket s = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    port = s.port;
    _server = s;
    s.listen((Socket client) async {
      try {
        final Socket up = await Socket.connect(upstream.host, upstream.port);
        _open
          ..add(client)
          ..add(up);
        unawaited(client.cast<List<int>>().pipe(up).catchError((Object _) {}));
        unawaited(up.cast<List<int>>().pipe(client).catchError((Object _) {}));
      } on Object {
        client.destroy();
      }
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final Socket s in _open) {
      s.destroy();
    }
    _open.clear();
  }

  String get url => 'http://127.0.0.1:$port';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Jellyfin 曲目：离线 / 删配置时的播放与收藏补发、客户端响度后备', (
    WidgetTester tester,
  ) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER',
    );
    await runFushiItest(
      label: 'music-server-offline',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel app = await enableFocusNavigation(tester);
        final FushiDatabase db = app.database;
        await app.prefsRepo.setMusicReplayGain(true);
        await app.prefsRepo.setMusicLoudnessScan(true);

        // ── 经转发口登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final Uri real = Uri.parse(JellyfinApi.normalizeServerUrl(_serverUrl));
        final _Relay relay = _Relay(real);
        await relay.start();
        addTearDown(relay.stop);
        final String url = JellyfinApi.normalizeServerUrl(relay.url);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        final JellyfinServerConfig config = JellyfinServerConfig(
          serverUrl: url,
          username: _username,
          userId: auth.userId,
          accessToken: auth.accessToken,
          serverName: auth.serverName,
        );
        final SyncRepository repo = SyncRepository(db);
        await repo.upsertJellyfinServer(config);
        app.musicServerTracks.invalidate();
        // 直连真服务器读 UserData（不经转发口，转发口关着时也能读）。
        final JellyfinApi direct = JellyfinApi(
          serverUrl: real.toString(),
          accessToken: auth.accessToken,
        );
        Future<Map<String, Object?>> userData(String itemId) async {
          final Object? j = await direct.getDecodedJson(
            '/Users/${auth.userId}/Items/$itemId',
          );
          return ((j! as Map<String, Object?>)['UserData']!
                  as Map<String, Object?>)
              .cast<String, Object?>();
        }

        final JellyfinMusicClient browser = JellyfinMusicClient(config);
        final MusicServerAlbum album = (await browser.search(
          _albumName,
        )).albums.firstWhere((MusicServerAlbum a) => a.title == _albumName);
        final List<MusicServerTrack> tracks = await browser.albumTracks(
          album.id,
        );
        MusicServerTrack named(String title) =>
            tracks.firstWhere((MusicServerTrack t) => t.title == title);
        final MusicServerTrack t1 = named('スピーチ 1');
        final MusicServerTrack t2 = named('スピーチ 2');
        final MusicServerTrack t3 = named('スピーチ 3');
        debugPrint(
          '[srv-offline] album=${album.title} tracks=${tracks.length} '
          'serverLoudness(t1)=${t1.loudness}',
        );
        expect(t1.loudness?.trackGainDb, isNull, reason: '开发服务器 LUFS 扫描是关的');

        // ── A1. 下两首离线副本（服务器没有响度 → sidecar 里是客户端测量值）──
        final MusicServerDownloadIndex index =
            MusicServerDownloadIndex.instance;
        final BuildContext ctx = tester.element(find.byType(HomePage));
        for (final MusicServerTrack t in <MusicServerTrack>[t1, t2]) {
          await musicServerDownloadServiceOf(
            ctx,
            db,
            browser,
          )!.download(browser, t, album: album);
        }
        final String uid1 = musicServerTrackUid(browser.serverId, t1.id);
        final String uid2 = musicServerTrackUid(browser.serverId, t2.id);
        for (int i = 0; i < 240; i++) {
          if (index.isDownloaded(uid1) && index.isDownloaded(uid2)) break;
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(index.isDownloaded(uid1) && index.isDownloaded(uid2), isTrue);
        final MusicServerDownloadRow row1 = index.rowOf(uid1)!;
        expect(row1.serverKind, 'jellyfin');
        final MusicServerDownloadSidecar? sidecar1 =
            await readMusicServerDownloadLoudness(row1.filePath);
        debugPrint(
          '[srv-offline] downloaded ${p(row1.filePath)} sidecar: '
          'server=${sidecar1?.server} measured=${sidecar1?.measured}',
        );
        expect(sidecar1?.server, isNull);
        expect(
          sidecar1?.measured?.trackGainDb,
          isNotNull,
          reason: '下完对本机文件测了响度',
        );

        // ── B1. 离线副本按 sidecar 的测量值施加增益 ──
        final MusicRemoteTrackRow lib1 = (await db.getMusicRemoteTrack(uid1))!;
        final MusicPlayItem copy1 = musicPlayItemOfRemote(
          lib1,
          server: (await musicServerBindingLoader!())[browser.serverId],
        )!;
        expect(copy1.path, row1.filePath);
        final double gain1 = await _playAndReadGain(tester, app, copy1);
        debugPrint(
          '[srv-offline] local copy play: volume-gain=$gain1 dB '
          '(measured ${sidecar1!.measured!.trackGainDb})',
        );
        expect(gain1, closeTo(sidecar1.measured!.trackGainDb!, 0.01));
        await app.musicSession.engine.stop();
        await tester.pump(const Duration(seconds: 1));
        // 那一次（已送达）的播放不算进下面的计数基线。
        await MusicServerOfflineQueue.instance.idle;

        final Map<String, Object?> before1 = await userData(t1.id);
        final Map<String, Object?> before2 = await userData(t2.id);
        debugPrint('[srv-offline] before: t1=$before1 t2=$before2');
        expect(await db.listMusicServerPendingActions(), isEmpty);

        // ── A2. 转发口关掉：客户端指向的地址连不上 ──
        await relay.stop();
        app.musicServerTracks.invalidate();
        final ({int from, int to}) window1 = await _playListened(
          tester,
          app,
          copy1,
        );
        debugPrint('[srv-offline] dead address: played t1 in $window1');
        // 收藏（「正在播放」同一个入口）。
        await app.musicSession.toggleFavorite(copy1);
        expect(app.musicSession.isFavorite(copy1), isTrue);
        List<MusicServerPendingActionRow> pending = await _waitPending(
          tester,
          db,
          2,
        );
        debugPrint(
          '[srv-offline] queued (dead address): '
          '${pending.map((MusicServerPendingActionRow r) => '${r.action}:${r.itemId}@${r.playedAt}').toList()}',
        );
        final int playedAt1 = pending
            .firstWhere(
              (MusicServerPendingActionRow r) =>
                  r.action == 'play' && r.itemId == t1.id,
            )
            .playedAt!;
        expect(playedAt1, inInclusiveRange(window1.from, window1.to));
        expect(
          pending.any(
            (MusicServerPendingActionRow r) =>
                r.action == 'favorite' && r.itemId == t1.id && r.favorite!,
          ),
          isTrue,
        );
        await captureFlutterFrame(tester, 'offline-queued', settle: false);

        // ── A3. 服务器配置删了：离线副本照样能放、照样带服务器身份 ──
        await repo.removeMediaServer(config.sourceId);
        app.musicServerTracks.invalidate();
        final MusicRemoteTrackRow lib2 = (await db.getMusicRemoteTrack(uid2))!;
        final MusicPlayItem copy2 = musicPlayItemOfRemote(lib2)!;
        expect(copy2.serverTrack?.kind, MusicServerKind.jellyfin);
        expect(copy2.serverTrack?.trackId, t2.id);
        final ({int from, int to}) window2 = await _playListened(
          tester,
          app,
          copy2,
        );
        debugPrint('[srv-offline] config removed: played t2 in $window2');
        pending = await _waitPending(tester, db, 3);
        final int playedAt2 = pending
            .firstWhere(
              (MusicServerPendingActionRow r) =>
                  r.action == 'play' && r.itemId == t2.id,
            )
            .playedAt!;
        expect(playedAt2, inInclusiveRange(window2.from, window2.to));
        // 服务器上还没动。
        expect((await userData(t1.id))['PlayCount'], before1['PlayCount']);

        // ── A4. 恢复：转发口重开、配置加回 → 补发（app 启动同一个 flushAll）──
        await relay.start();
        await repo.upsertJellyfinServer(config);
        app.musicServerTracks.invalidate();
        await MusicServerOfflineQueue.instance.flushAll();
        await MusicServerOfflineQueue.instance.idle;
        final Map<String, Object?> after1 = await userData(t1.id);
        final Map<String, Object?> after2 = await userData(t2.id);
        debugPrint('[srv-offline] after flush: t1=$after1 t2=$after2');
        expect(after1['PlayCount'], (before1['PlayCount']! as int) + 1);
        expect(after2['PlayCount'], (before2['PlayCount']! as int) + 1);
        expect(after1['IsFavorite'], isTrue);
        int secondsOf(Object? iso) =>
            DateTime.parse(iso! as String).millisecondsSinceEpoch ~/ 1000;
        expect(secondsOf(after1['LastPlayedDate']), playedAt1 ~/ 1000);
        expect(secondsOf(after2['LastPlayedDate']), playedAt2 ~/ 1000);
        expect(await db.listMusicServerPendingActions(), isEmpty);
        await captureFlutterFrame(tester, 'offline-flushed', settle: false);

        // ── B2. 串流曲目：播过一次 → 后台从服务器流测一次 → 再播按测量值施加 ──
        final MusicRemoteTracksCompanion r3 = musicServerRemoteTrackCompanion(
          browser,
          t3,
          albumTitle: album.title,
        )!;
        await db.addMusicRemoteTrackToLibrary(
          r3,
          at: DateTime.now().millisecondsSinceEpoch,
        );
        Future<MusicPlayItem> streamItem() async => musicPlayItemOfRemote(
          (await db.getMusicRemoteTrack(r3.trackUid.value))!,
          server: (await musicServerBindingLoader!())[browser.serverId],
        )!;
        final MusicPlayItem s1 = await streamItem();
        expect(s1.path, startsWith('http'));
        await _playListened(tester, app, s1);
        MusicServerTrackStateRow? state;
        for (int i = 0; i < 240; i++) {
          state = await db.getMusicServerTrackState(s1.trackUid);
          if (state?.loudnessMeasuredAt != null) break;
          await tester.pump(const Duration(milliseconds: 250));
        }
        debugPrint(
          '[srv-offline] stream measured: gain=${state?.measuredTrackGain} '
          'peak=${state?.measuredTrackPeak}',
        );
        expect(state?.measuredTrackGain, isNotNull);
        expect('${state!.toJson()}', isNot(contains('api_key')));
        final double gain3 = await _playAndReadGain(
          tester,
          app,
          await streamItem(),
        );
        debugPrint(
          '[srv-offline] stream replay: volume-gain=$gain3 dB '
          '(measured ${state.measuredTrackGain})',
        );
        expect(gain3, closeTo(state.measuredTrackGain!, 0.01));
        await app.musicSession.engine.stop();
        await captureFlutterFrame(tester, 'loudness-fallback', settle: false);

        // 收尾：取消收藏，服务器状态还原（下次跑的基线一致）。
        await browser.setFavorite(
          MusicServerItemKind.track,
          t1.id,
          favorite: false,
        );
      },
    );
  });
}

String p(String path) => path.split(RegExp(r'[\\/]')).last;

/// 放 [item]，等 mpv 的 volume-gain 落定（非 0），回读到的增益。
Future<double> _playAndReadGain(
  WidgetTester tester,
  AppModel app,
  MusicPlayItem item,
) async {
  await app.musicSession.engine.playQueue(<MusicPlayItem>[item]);
  MusicSignalPathSnapshot? snap;
  for (int i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    snap = await app.musicSession.engine.readSignalPath();
    if (snap != null && snap.volumeGainDb.abs() > 1e-6) break;
  }
  return snap?.volumeGainDb ?? 0;
}

/// 放 [item] 到听够门槛（9 s 的曲目听 6 s）再停，回开播时刻所在的时间窗（毫秒）。
Future<({int from, int to})> _playListened(
  WidgetTester tester,
  AppModel app,
  MusicPlayItem item,
) async {
  final int from = DateTime.now().millisecondsSinceEpoch;
  await app.musicSession.engine.playQueue(<MusicPlayItem>[item]);
  final int to = DateTime.now().millisecondsSinceEpoch + 2000;
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (app.musicSession.engine.position >= const Duration(seconds: 6)) break;
  }
  expect(
    app.musicSession.engine.position,
    greaterThanOrEqualTo(const Duration(seconds: 5)),
  );
  await app.musicSession.engine.stop();
  await tester.pump(const Duration(milliseconds: 500));
  return (from: from, to: to);
}

Future<List<MusicServerPendingActionRow>> _waitPending(
  WidgetTester tester,
  FushiDatabase db,
  int count,
) async {
  List<MusicServerPendingActionRow> rows = <MusicServerPendingActionRow>[];
  for (int i = 0; i < 80; i++) {
    rows = await db.listMusicServerPendingActions();
    if (rows.length >= count) break;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return rows;
}
