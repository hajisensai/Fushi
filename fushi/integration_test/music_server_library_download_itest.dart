import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真 Jellyfin 上的服务器专辑「加入音乐库」+ 离线下载（v172）：
///
/// 1. 用 dart-define 给的开发服务器登录，配成媒体服务器（音乐复用这份登录）；
/// 2. 打开一张真专辑，焦点驱动按「加入音乐库」→ 库里整张在、按钮变「已在音乐库」；
/// 3. 焦点驱动按「下载」→ 原文件经 `/Items/{id}/Download` 落到下载根、副本行落库；
/// 4. 起播：引擎打开的是本地文件路径；再拿一个**地址不可达**的同身份客户端（等同服务器离线）
///    起播同一张专辑，照样是本地文件、播放位置在走；删掉服务器配置后曲库里的这几首仍可用。
///
/// 需要 `--dart-define=FUSHI_ITEST_JF_URL=… FUSHI_ITEST_JF_USER=… FUSHI_ITEST_JF_PASS=…
/// FUSHI_ITEST_JF_ALBUM=<专辑名>`；没给时跳过。不停共享的服务器容器。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String url = String.fromEnvironment('FUSHI_ITEST_JF_URL');
  const String user = String.fromEnvironment('FUSHI_ITEST_JF_USER');
  const String pass = String.fromEnvironment('FUSHI_ITEST_JF_PASS');
  const String albumName = String.fromEnvironment(
    'FUSHI_ITEST_JF_ALBUM',
    defaultValue: 'Rock Album',
  );

  testWidgets('服务器专辑：加入音乐库、离线下载、断开服务器仍放本地文件', (WidgetTester tester) async {
    if (url.isEmpty) {
      markTestSkipped('FUSHI_ITEST_JF_URL not given');
      return;
    }
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel app = await enableFocusNavigation(tester);
    final FocusDriver focus = FocusDriver(tester);
    final FushiDatabase db = app.database;

    // 1. 登录开发服务器，配成媒体服务器。
    final JellyfinApi auth = JellyfinApi(
      serverUrl: url,
      deviceId: 'fushi-itest-music',
    );
    final JellyfinAuthResult login =
        await tester.runAsync(() => auth.authenticateByName(user, pass))
            as JellyfinAuthResult;
    final JellyfinServerConfig config = JellyfinServerConfig(
      serverUrl: url,
      username: user,
      userId: login.userId,
      accessToken: login.accessToken,
      serverName: 'Dev Jellyfin',
      deviceId: 'fushi-itest-music',
    );
    await tester.runAsync(() => SyncRepository(db).upsertMediaServer(config));
    final JellyfinMusicClient client = JellyfinMusicClient(config);

    final MusicServerAlbum album = (await tester.runAsync(
      () => client.listAlbums(),
    ))!.items.firstWhere((MusicServerAlbum a) => a.title == albumName);
    final List<MusicServerTrack> tracks = (await tester.runAsync(
      () => client.albumTracks(album.id),
    ))!;
    expect(tracks, isNotEmpty);
    final List<String> uids = <String>[
      for (final MusicServerTrack t in tracks)
        musicServerTrackUid(client.serverId, t.id),
    ];

    // 2. 打开专辑页，焦点驱动「加入音乐库」。
    unawaited(
      app.navigatorKey.currentState!.push<void>(
        adaptivePageRoute<void>(
          context: app.navigatorKey.currentContext!,
          builder: (_) => MusicServerAlbumPage(browser: client, album: album),
        ),
      ),
    );
    Future<void> settleFrames([int n = 12]) async {
      for (int i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settleFrames(30);
    const ValueKey<String> libraryKey = ValueKey<String>(
      'music-server-collection-library',
    );
    const ValueKey<String> downloadKey = ValueKey<String>(
      'music-server-collection-download',
    );
    expect(find.byKey(libraryKey), findsOneWidget);
    await captureFlutterFrame(tester, 'jf_album_before', settle: false);

    bool focusIn(Key key) {
      final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      bool hit = ctx.widget.key == key;
      ctx.visitAncestorElements((Element e) {
        if (e.widget.key == key) hit = true;
        return !hit;
      });
      return hit;
    }

    expect(
      await focus.focusUntil(() => focusIn(libraryKey), maxSteps: 120),
      isTrue,
      reason: 'Tab 应能走到「加入音乐库」',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleFrames();
    final Set<String> inLibrary = (await tester.runAsync(
      () => db.musicRemoteLibraryUidsOf(uids),
    ))!;
    expect(inLibrary, uids.toSet(), reason: '整张专辑应在音乐库里');
    await captureFlutterFrame(tester, 'jf_album_in_library', settle: false);

    // 3. 焦点驱动「下载」，等全部副本落地。
    expect(
      await focus.focusUntil(() => focusIn(downloadKey), maxSteps: 40),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final MusicServerDownloadIndex index = MusicServerDownloadIndex.instance;
    for (int i = 0; i < 600 && index.countDownloaded(uids) < uids.length; i++) {
      await settleFrames(1);
    }
    expect(index.countDownloaded(uids), uids.length, reason: '整张都应下完');
    await settleFrames(5);
    await captureFlutterFrame(tester, 'jf_album_downloaded', settle: false);
    for (final String uid in uids) {
      final MusicServerDownloadRow row = index.rowOf(uid)!;
      expect(File(row.filePath).existsSync(), isTrue);
      expect(row.filePath, isNot(contains('api_key')));
      // ignore: avoid_print
      print('[itest] downloaded $uid -> ${row.filePath} (${row.sizeBytes} B)');
    }

    // 4a. 服务器页起播：引擎拿到的是本地文件。
    final List<MusicPlayItem> items = <MusicPlayItem>[
      for (final MusicServerTrack t in tracks) musicServerPlayItem(client, t),
    ];
    expect(items.first.path, index.rowOf(uids.first)!.filePath);

    // 4b. 同身份、地址不可达的客户端（等同服务器离线）：照样放本地文件。
    final JellyfinServerConfig dead = JellyfinServerConfig(
      serverUrl: url,
      username: user,
      userId: login.userId,
      accessToken: login.accessToken,
      deviceId: 'fushi-itest-music',
      alternateUrls: const <String>['http://127.0.0.1:9'],
      activeServerUrl: 'http://127.0.0.1:9',
    );
    final JellyfinMusicClient offline = JellyfinMusicClient(dead);
    expect(offline.serverId, client.serverId);
    expect(
      offline.streamFor(tracks.first).uri.toString(),
      startsWith('http://127.0.0.1:9'),
      reason: '这个客户端串流一定失败',
    );
    final List<MusicPlayItem> offlineItems = <MusicPlayItem>[
      for (final MusicServerTrack t in tracks) musicServerPlayItem(offline, t),
    ];
    await tester.runAsync(
      () => app.musicSession.engine.playQueue(offlineItems),
    );
    Duration pos = Duration.zero;
    for (int i = 0; i < 60 && pos < const Duration(milliseconds: 500); i++) {
      await settleFrames(1);
      pos = app.musicSession.engine.position;
    }
    final MusicPlayItem? current = app.musicSession.engine.current;
    // ignore: avoid_print
    print('[itest] offline playing ${current?.path} at $pos');
    expect(current?.path, index.rowOf(uids.first)!.filePath);
    expect(File(current!.path).existsSync(), isTrue);
    expect(pos, greaterThan(Duration.zero), reason: '本地文件应在播放');
    await captureFlutterFrame(tester, 'jf_offline_playing', settle: false);
    await tester.runAsync(() => app.musicSession.engine.stop());

    // 4c. 删掉服务器配置：曲库里这几首仍可用（离线副本）。
    await tester.runAsync(
      () => SyncRepository(db).setMediaServers(<MediaServerConfig>[]),
    );
    final MusicLibrarySnapshot snap = (await tester.runAsync(
      () => MusicLibrarySnapshot.load(db),
    ))!;
    final List<MusicRemoteEntry> mine = <MusicRemoteEntry>[
      for (final MusicRemoteEntry e in snap.remoteTracks)
        if (uids.contains(e.trackUid)) e,
    ];
    expect(mine.length, uids.length);
    expect(mine.every((MusicRemoteEntry e) => e.available), isTrue);
    expect(mine.every((MusicRemoteEntry e) => e.server == null), isTrue);
    expect(
      mine.first.playItem(const <String, MusicAlbumRow>{})?.path,
      index.rowOf(mine.first.trackUid)!.filePath,
    );

    // 收尾：移出曲库 → 离线副本连文件删掉（下载 ⊂ 音乐库）。
    final String anyFile = index.rowOf(uids.first)!.filePath;
    await tester.runAsync(() async {
      await db.removeMusicRemoteTracksFromLibrary(uids, at: 1);
      await index.dropDownloadsOutsideLibrary(uids);
    });
    await settleFrames(5);
    expect(File(anyFile).existsSync(), isFalse);
    expect(index.countDownloaded(uids), 0);
    app.navigatorKey.currentState!.pop();
    await settleFrames(5);
    expect(
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first)),
      isNotNull,
    );
  });
}
