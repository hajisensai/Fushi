// 服务器专辑 / 艺人整体「加入 / 移出音乐库」与离线状态（Jellyfin / Subsonic，v172）。
//
// 专辑页头部的入库按钮显示「都不在 / 部分 / 全部」三态，点一下整张加入（一个事务）；全部 /
// 部分在库时点开菜单可移出。曲目行上有离线副本的显示「已下载」角标。艺人页同一套按钮覆盖
// 该艺人全部专辑的曲目。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart'
    show kAppleMusicNativeEventChannel;
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show musicServerLocalCopyLookup;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

const MusicServerAlbum _album = MusicServerAlbum(
  id: 'alb1',
  title: 'Rock Album',
  artist: 'Band',
  artistId: 'art1',
);
const MusicServerAlbum _album2 = MusicServerAlbum(
  id: 'alb2',
  title: 'Second Album',
  artist: 'Band',
  artistId: 'art1',
);

List<MusicServerTrack> _tracksOf(String albumId) => <MusicServerTrack>[
  for (int i = 1; i <= 3; i++)
    MusicServerTrack(
      id: '$albumId-t$i',
      title: '$albumId track $i',
      albumId: albumId,
      trackNo: i,
      container: 'flac',
    ),
];

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel(kAppleMusicNativeEventChannel),
          MockStreamHandler.inline(
            onListen: (Object? _, MockStreamHandlerEventSink __) {},
          ),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel(kAppleMusicNativeEventChannel),
          null,
        );
    musicServerLocalCopyLookup = null;
  });

  Future<({FushiDatabase db, AppModel app})> harness(
    WidgetTester tester,
    Widget home,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(prefs.loadFromDb);
    final AppModel app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp,
      )
      ..wireDatabaseForTesting(db);
    MusicServerDownloadIndex.instance.attach(db);
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: home,
          ),
        ),
      ),
    );
    await _settle(tester);
    return (db: db, app: app);
  }

  Finder libraryButton() =>
      find.byKey(const ValueKey<String>('music-server-collection-library'));

  testWidgets('专辑页：整张加入音乐库 → 已在音乐库；菜单移出；部分在库显示计数', (WidgetTester tester) async {
    final _FakeServer server = _FakeServer();
    final h = await harness(
      tester,
      MusicServerAlbumPage(browser: server, album: _album),
    );
    expect(libraryButton(), findsOneWidget);
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(t.music_action_add_to_library),
      ),
      findsOneWidget,
    );

    await tester.tap(libraryButton());
    await _settle(tester);
    final List<String> uids = <String>[
      for (final MusicServerTrack tr in _tracksOf('alb1'))
        musicServerTrackUid(server.serverId, tr.id),
    ];
    final Set<String> inLib = (await tester.runAsync(
      () => h.db.musicRemoteLibraryUidsOf(uids),
    ))!;
    expect(inLib, uids.toSet());
    final MusicRemoteTrackRow row = (await tester
        .runAsync<MusicRemoteTrackRow?>(
          () => h.db.getMusicRemoteTrack(uids.first),
        ))!;
    expect(row.kind, MusicRemoteTrackKind.server.wire);
    expect(row.album, 'Rock Album');
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(t.music_server_library_state_all),
      ),
      findsOneWidget,
    );

    // 移出一首（别的入口）→ 部分在库。
    await tester.runAsync(
      () => h.db.removeMusicRemoteTracksFromLibrary(<String>[uids.last], at: 9),
    );
    await _settle(tester);
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(
          t.music_server_library_state_partial(have: 2, total: 3),
        ),
      ),
      findsOneWidget,
    );

    // 部分在库：点开菜单 → 移出整张。
    await tester.tap(libraryButton());
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>(
          'music-menu-action-serverCollectionAddToLibrary',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'music-menu-action-serverCollectionRemoveFromLibrary',
        ),
      ),
    );
    await _settle(tester);
    expect(
      (await tester.runAsync(() => h.db.musicRemoteLibraryUidsOf(uids)))!,
      isEmpty,
    );
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(t.music_action_add_to_library),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('曲目行：有离线副本的显示「已下载」角标，下载按钮显示已下载计数', (WidgetTester tester) async {
    final _FakeServer server = _FakeServer();
    final Directory dir = Directory.systemTemp.createTempSync('musalb');
    addTearDown(() => dir.deleteSync(recursive: true));
    final MusicServerTrack first = _tracksOf('alb1').first;
    final String uid = musicServerTrackUid(server.serverId, first.id);
    final String file = p.join(dir.path, '01.flac');
    File(file).writeAsBytesSync(<int>[1, 2, 3]);

    final h = await harness(
      tester,
      MusicServerAlbumPage(browser: server, album: _album),
    );
    await tester.runAsync(
      () => h.db.recordMusicServerDownload(
        MusicServerDownloadsCompanion.insert(
          trackUid: uid,
          sourceKey: server.serverId,
          itemId: first.id,
          filePath: file,
          downloadedAt: 1,
        ),
        track: musicServerRemoteTrackCompanion(server, first)!,
        at: 1,
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(ValueKey<String>('music-server-track-downloaded-$uid')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('music-server-collection-download'),
        ),
        matching: find.text(
          t.music_server_download_state_partial(have: 1, total: 3),
        ),
      ),
      findsOneWidget,
    );
    // 下载即入库：这首在库 → 入库按钮是部分在库。
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(
          t.music_server_library_state_partial(have: 1, total: 3),
        ),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('艺人页：按钮覆盖全部专辑的曲目，整位艺人加入音乐库', (WidgetTester tester) async {
    final _FakeServer server = _FakeServer();
    final h = await harness(
      tester,
      MusicServerArtistPage(
        browser: server,
        artist: const MusicServerArtist(id: 'art1', name: 'Band'),
      ),
    );
    expect(libraryButton(), findsOneWidget);
    await tester.tap(libraryButton());
    await _settle(tester);
    final List<String> uids = <String>[
      for (final MusicServerTrack tr in <MusicServerTrack>[
        ..._tracksOf('alb1'),
        ..._tracksOf('alb2'),
      ])
        musicServerTrackUid(server.serverId, tr.id),
    ];
    expect(
      (await tester.runAsync(() => h.db.musicRemoteLibraryUidsOf(uids)))!,
      uids.toSet(),
    );
    // 每首记的是自己那张专辑的名字。
    final MusicRemoteTrackRow second = (await tester
        .runAsync<MusicRemoteTrackRow?>(
          () => h.db.getMusicRemoteTrack(uids.last),
        ))!;
    expect(second.album, 'Second Album');
    expect(
      find.descendant(
        of: libraryButton(),
        matching: find.text(t.music_server_library_state_all),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

class _FakeServer implements MusicServerBrowser, MusicServerDownloading {
  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  @override
  String get serverId => 'jf-dev';

  @override
  String get displayName => 'Dev Jellyfin';

  @override
  MusicServerDownloadSource downloadSourceFor(MusicServerTrack track) =>
      MusicServerDownloadSource(
        uri: Uri.parse('http://jf.test/Items/${track.id}/Download'),
      );

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse('http://jf.test/stream/${track.id}'),
        transcoded: false,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) => null;

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async => const MusicServerPage<MusicServerAlbum>(
    items: <MusicServerAlbum>[_album, _album2],
  );

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async =>
      _tracksOf(albumId);

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[_album, _album2];

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async => const MusicServerPage<MusicServerPlaylist>(
    items: <MusicServerPlaylist>[],
  );

  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async =>
      const <MusicServerTrack>[];

  @override
  Future<MusicServerSearchResult> search(
    String query, {
    int limit = 30,
  }) async => const MusicServerSearchResult();

  @override
  void close() {}
}
