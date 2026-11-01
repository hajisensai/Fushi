// 服务器曲库（音乐方案 §13 P5）：Jellyfin 音乐客户端（复用视频的 JellyfinApi 传输与凭据）、
// 播放项换算、服务器页与「混排进曲库」的页面接线。

import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show AppleMusicCatalogClient;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/test_platform_services.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;

const JellyfinServerConfig _config = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'me',
  userId: 'uid',
  accessToken: 'tok',
  serverName: 'Home NAS',
);

Map<String, Object?> _album(String id) => <String, Object?>{
  'Id': id,
  'Name': 'Album $id',
  'AlbumArtist': 'Singer',
  'ImageTags': <String, Object?>{'Primary': 't'},
};

Map<String, Object?> _audio(String id, int no) => <String, Object?>{
  'Id': id,
  'Name': 'Song $id',
  'AlbumId': 'a1',
  'IndexNumber': no,
  'RunTimeTicks': 1800000000,
  'MediaStreams': <Object?>[
    <String, Object?>{
      'Type': 'Audio',
      'Codec': 'flac',
      'SampleRate': 44100,
      'BitDepth': 16,
      'Channels': 2,
    },
  ],
};

/// 假浏览器：页面测试只看渲染与接线，不起网络。
class _FakeBrowser implements MusicServerBrowser {
  @override
  MusicServerKind get kind => MusicServerKind.subsonic;

  @override
  String get serverId => 'subsonic-1';

  @override
  String get displayName => 'Navidrome';

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async => const MusicServerPage<MusicServerAlbum>(
    items: <MusicServerAlbum>[
      MusicServerAlbum(id: 'a1', title: 'Remote Album', artist: 'Band'),
    ],
  );

  @override
  Future<List<MusicServerTrack>> albumTracks(
    String albumId,
  ) async => const <MusicServerTrack>[
    MusicServerTrack(id: 't1', title: 'First', trackNo: 1, durationMs: 61000),
    MusicServerTrack(id: 't2', title: 'Second', trackNo: 2),
  ];

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[MusicServerArtist(id: 'r1', name: 'Band')];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[];

  @override
  Future<MusicServerSearchResult> search(
    String query, {
    int limit = 30,
  }) async => const MusicServerSearchResult();

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse('http://navi/rest/stream?id=${track.id}'),
        transcoded: maxBitrateKbps != null,
        codec: maxBitrateKbps != null ? 'opus' : track.codec,
        bitrateKbps: maxBitrateKbps,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) => null;

  @override
  void close() {}
}

Future<void> _pump(WidgetTester tester, AppModel app, Widget home) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((Ref ref) => app)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 没装任何插件的插件管理器：根目录不存在，列表恒空，不碰磁盘。
MusicPluginManager _noPlugins() => MusicPluginManager(
  rootDir: Directory(
    '${Directory.systemTemp.path}/fushi-music-server-test-no-plugins',
  ),
  httpClientFactory: HttpClient.new,
  log: (_, _, _) {},
);

void main() {
  group('Jellyfin 音乐客户端', () {
    test('专辑分页 / 曲目 / 搜索 / 流 / 封面：同一份认证头、令牌在 query', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request req) async {
        requests.add(req);
        final Map<String, String> q = req.url.queryParameters;
        Object body = <String, Object?>{'Items': <Object?>[]};
        if (req.url.path == '/Users/uid/Items' &&
            q['IncludeItemTypes'] == 'MusicAlbum' &&
            q['SearchTerm'] == null) {
          body = <String, Object?>{
            'Items': <Object?>[_album('a1'), _album('a2')],
            'TotalRecordCount': 3,
          };
        } else if (req.url.path == '/Users/uid/Items' &&
            q['ParentId'] == 'a1') {
          body = <String, Object?>{
            'Items': <Object?>[_audio('t2', 2), _audio('t1', 1)],
          };
        }
        return http.Response(jsonEncode(body), 200);
      });
      final JellyfinMusicClient mb = JellyfinMusicClient(
        _config,
        httpClient: client,
      );
      expect(mb.serverId, _config.sourceId);
      expect(mb.displayName, 'Home NAS');

      final MusicServerPage<MusicServerAlbum> page = await mb.listAlbums(
        limit: 2,
      );
      expect(page.items.map((MusicServerAlbum a) => a.id), <String>[
        'a1',
        'a2',
      ]);
      expect(page.nextOffset, 2);
      expect(requests.single.headers['Authorization'], contains('Token="tok"'));
      expect(requests.single.url.queryParameters['Recursive'], 'true');

      final List<MusicServerTrack> tracks = await mb.albumTracks('a1');
      expect(tracks.map((MusicServerTrack t) => t.id), <String>['t1', 't2']);
      expect(tracks.first.isLossless, isTrue);

      requests.clear();
      await mb.search('  night ');
      expect(requests, hasLength(3));
      expect(
        requests.map((http.Request r) => r.url.queryParameters['SearchTerm']),
        everyElement('night'),
      );
      requests.clear();
      expect((await mb.search('   ')).isEmpty, isTrue);
      expect(requests, isEmpty);

      final MusicServerStream direct = mb.streamFor(tracks.first);
      expect(
        direct.uri.toString(),
        startsWith('http://nas:8096/Audio/t1/stream?'),
      );
      expect(direct.uri.queryParameters['api_key'], 'tok');
      expect(direct.transcoded, isFalse);
      expect(direct.codec, 'flac');
      final MusicServerStream capped = mb.streamFor(
        tracks.first,
        maxBitrateKbps: 128,
      );
      expect(capped.uri.path, '/Audio/t1/universal');
      expect(capped.transcoded, isTrue);
      expect(
        mb.coverUri('a1').toString(),
        startsWith('http://nas:8096/Items/a1/Images/Primary?'),
      );
    });
  });

  test('播放项：原样直出带源属性；转码时源属性按转码后的（信号路径不判 bit-perfect）', () {
    final _FakeBrowser b = _FakeBrowser();
    const MusicServerTrack track = MusicServerTrack(
      id: 't1',
      title: 'First',
      albumId: 'a1',
      codec: 'flac',
      sampleRate: 96000,
      bitDepth: 24,
      channels: 2,
    );
    final MusicPlayItem direct = musicServerPlayItem(b, track);
    expect(direct.path, 'http://navi/rest/stream?id=t1');
    expect(direct.codec, 'flac');
    expect(direct.sampleRate, 96000);
    expect(direct.trackUid, musicServerTrackUid('subsonic-1', 't1'));
    expect(direct.albumUid, musicServerAlbumUid('subsonic-1', 'a1'));
    final MusicPlayItem capped = musicServerPlayItem(
      b,
      track,
      maxBitrateKbps: musicServerBitrateLimit(192),
    );
    expect(capped.codec, 'opus');
    expect(capped.sampleRate, isNull);
    expect(capped.bitDepth, isNull);
    expect(musicServerBitrateLimit(0), isNull);
  });

  testWidgets('服务器页：清单 → 专辑 → 曲目', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final _FakeBrowser browser = _FakeBrowser();
    await _pump(
      tester,
      app,
      MusicServerListPage(loader: () async => <MusicServerBrowser>[browser]),
    );
    expect(find.text('Navidrome'), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-server-subsonic-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remote Album'), findsOneWidget);
    await tester.tap(find.text('Remote Album'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('混排进曲库：服务器专辑排在本地专辑之后、带云朵', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final _FakeBrowser browser = _FakeBrowser();
    await _pump(
      tester,
      app,
      MusicLibraryPage(
        serverAlbumsLoader: () async => <MusicServerAlbumRef>[
          MusicServerAlbumRef(
            browser: browser,
            album: const MusicServerAlbum(id: 'a1', title: 'Remote Album'),
          ),
        ],
      ),
    );
    expect(find.text('Remote Album'), findsOneWidget);
    expect(find.byType(MusicServerAlbumCard), findsOneWidget);
    // 空的本地曲库有了服务器专辑就不再显示「添加文件夹」空态。
    expect(find.text(t.music_library_empty), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('混排开关与码率偏好：读写往返；偏好没装好时不抛', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    expect(prefs.musicServerLibraryMix, isEmpty);
    await prefs.setMusicServerLibraryMix(<String>{'b', 'a'});
    expect(prefs.musicServerLibraryMix, <String>{'a', 'b'});
    await prefs.setMusicServerMaxBitrate(192);
    expect(prefs.musicServerMaxBitrate, 192);
    expect(prefs.musicSubsonicServers, isEmpty);

    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    expect(app.isPreferencesReady, isFalse);
    expect(await loadMusicServerBrowsers(app), isEmpty);
    expect(await loadMixedServerAlbums(app), isEmpty);
  });

  test('Apple Music：默认关、storefront 归一化往返；不参与混排', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    expect(prefs.musicAppleMusicEnabled, isFalse);
    expect(prefs.musicAppleMusicStorefront, 'jp');
    await prefs.setMusicAppleMusicEnabled(true);
    await prefs.setMusicAppleMusicStorefront('US');
    expect(prefs.musicAppleMusicEnabled, isTrue);
    expect(prefs.musicAppleMusicStorefront, 'us');
    await prefs.setMusicAppleMusicStorefront('not-a-storefront');
    expect(prefs.musicAppleMusicStorefront, 'jp');

    expect(musicServerSupportsLibraryMix(MusicServerKind.appleMusic), isFalse);
    expect(musicServerSupportsLibraryMix(MusicServerKind.jellyfin), isTrue);
    expect(musicServerSupportsLibraryMix(MusicServerKind.subsonic), isTrue);
  });

  test(
    'Apple Music 开关生效：开 = 来源清单里有 catalog 客户端且用设置的 storefront；关 = 没有',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      final Directory dir = await Directory.systemTemp.createTemp('fushi_am_');
      addTearDown(() => dir.delete(recursive: true));
      final AppModel app = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir)
        ..wireDatabaseForTesting(db)
        ..wireMusicPluginManagerForTesting(_noPlugins());
      expect(app.isPreferencesReady, isTrue);

      expect(
        (await loadMusicServerBrowsers(
          app,
        )).whereType<AppleMusicCatalogClient>(),
        isEmpty,
      );
      await prefs.setMusicAppleMusicEnabled(true);
      await prefs.setMusicAppleMusicStorefront('us');
      final List<AppleMusicCatalogClient> on = (await loadMusicServerBrowsers(
        app,
      )).whereType<AppleMusicCatalogClient>().toList();
      expect(on, hasLength(1));
      expect(on.single.storefront, 'us');
      await prefs.setMusicAppleMusicEnabled(false);
      expect(
        (await loadMusicServerBrowsers(
          app,
        )).whereType<AppleMusicCatalogClient>(),
        isEmpty,
      );
    },
  );
}
