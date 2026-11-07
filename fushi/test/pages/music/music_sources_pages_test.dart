// 音乐「来源」页与「推荐」来源 chip：排序 / 开关写回偏好时保留暂时不在场的来源；
// 「全部」里服务器那排专辑跟着数据源（换 storefront = 换浏览器）重新拉取；选中的来源消失后
// chip 与内容一起回到「全部」；服务器从推荐页 chip 进入：专辑 → 曲目。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart'
    show kAppleMusicNativeEventChannel;
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_sources_page.dart';
import 'package:fushi/src/pages/implementations/music/music_server_settings.dart';
import 'package:fushi/src/pages/implementations/music/music_sources_recommend.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart'
    show buildMusicServersDestination;
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 假服务器：记 [listAlbums] 调了几次，专辑名带 serverId 以区分数据源。
class _FakeBrowser implements MusicServerBrowser {
  _FakeBrowser(this.serverId);

  @override
  final String serverId;

  @override
  String get displayName => 'Navidrome';

  int listAlbumsCalls = 0;

  @override
  MusicServerKind get kind => MusicServerKind.subsonic;

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    listAlbumsCalls++;
    return MusicServerPage<MusicServerAlbum>(
      items: <MusicServerAlbum>[
        MusicServerAlbum(id: 'a1', title: 'Album $serverId', artist: 'Band'),
      ],
    );
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(
    String albumId,
  ) async => const <MusicServerTrack>[
    MusicServerTrack(id: 't1', title: 'First', trackNo: 1, durationMs: 61000),
    MusicServerTrack(id: 't2', title: 'Second', trackNo: 2),
  ];

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[];

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
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse('http://navi/rest/stream?id=${track.id}'),
        transcoded: false,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) => null;

  @override
  void close() {}
}

MusicPluginManager _noPlugins() => MusicPluginManager(
  rootDir: Directory(
    '${Directory.systemTemp.path}/fushi-music-sources-test-no-plugins',
  ),
  httpClientFactory: HttpClient.new,
  log: (_, _, _) {},
);

typedef _Env = ({AppModel app, PreferencesRepository prefs});

/// 真 IO / 数据库在 testWidgets 的假时钟里不会完成：环境搭建与偏好写入一律走 runAsync。
Future<_Env> _env(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(prefs.loadFromDb);
  // 不建临时目录：这些页面不碰数据库目录下的文件。
  final Directory dir = Directory.systemTemp;
  final AppModel app = AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir)
    ..wireDatabaseForTesting(db)
    ..wireMusicPluginManagerForTesting(_noPlugins());
  return (app: app, prefs: prefs);
}

Widget _host(AppModel app, Widget home) {
  LocaleSettings.setLocale(AppLocale.en);
  return ProviderScope(
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
  );
}

SubsonicServerConfig _subsonic(String id, {bool enabled = true}) =>
    SubsonicServerConfig(
      id: id,
      name: 'Server $id',
      serverUrl: Uri.parse('https://$id.example.invalid'),
      apiKey: 'k',
      enabled: enabled,
    );

List<LyricsProviderEntry> _stored(PreferencesRepository prefs) =>
    parseLyricsProviders(prefs.musicOnlineSourcesRaw);

bool _chipSelected(WidgetTester tester, String key) =>
    tester.widget<FushiChoiceChip>(find.byKey(ValueKey<String>(key))).selected;

/// 让真 IO（插件目录、内存库查询）在真时钟里落地，再把帧推平。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // 宿主是 macOS 14+ 时 createAppleMusicBridge 给的是原生桥，flutter test 里没有插件，
    // 订阅事件通道会报 MissingPluginException（Windows / Linux 宿主走网页桥 / null，不受影响）。
    // 给一个不发事件的桩：页面只读「本平台能不能整曲播」，不靠原生事件。
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
  });

  testWidgets('来源页「添加 › 服务器」推的是 设置 › 在线服务 › 媒体服务器 里那一页（同一棵树）', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    final _Env env = await _env(tester);
    await tester.pumpWidget(_host(env.app, const MusicSourcesPage()));
    await _settle(tester);

    await tester.tap(find.text(t.music_sources_add));
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('music_sources_add_server')),
    );
    await _settle(tester);

    final SettingsDetailPage page = tester.widget<SettingsDetailPage>(
      find.byType(SettingsDetailPage),
    );
    expect(page.subPageBuilder, equals(buildMusicServersDestination));
    expect(find.byType(MusicServerSettingsBody), findsOneWidget);
    expect(find.text(t.music_server_bitrate_title), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('来源页：排序 / 开关写回时，停用中的服务器的顺序与隐藏原样保留', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    final _Env env = await _env(tester);
    // b 被停用（这次加载不到），它在偏好里排最前且被隐藏。
    await tester.runAsync(() async {
      await env.prefs.setMusicSubsonicServers(<SubsonicServerConfig>[
        _subsonic('a'),
        _subsonic('b', enabled: false),
        _subsonic('c'),
      ]);
      await env.prefs.setMusicOnlineSourcesRaw(
        serializeLyricsProviders(const <LyricsProviderEntry>[
          LyricsProviderEntry(id: 'server:subsonic-b', enabled: false),
          LyricsProviderEntry(id: 'server:subsonic-a', enabled: true),
          LyricsProviderEntry(id: 'server:subsonic-c', enabled: true),
        ]),
      );
    });
    await tester.pumpWidget(_host(env.app, const MusicSourcesPage()));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('music-source-server:subsonic-b')),
      findsNothing,
    );
    // a 下移一位：可见顺序 c, a, apple-music。
    await tester.tap(
      find.byKey(const ValueKey<String>('music-source-down-server:subsonic-a')),
    );
    await _settle(tester);
    expect(
      _stored(env.prefs).map((LyricsProviderEntry e) => e.id).toList(),
      <String>[
        'server:subsonic-b',
        'server:subsonic-c',
        'server:subsonic-a',
        kAppleMusicSourceKey,
      ],
    );
    expect(_stored(env.prefs).first.enabled, isFalse);

    // 关掉 c 的显示。
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('music-source-toggle-server:subsonic-c'),
        ),
        matching: find.byType(Switch),
      ),
    );
    await _settle(tester);
    final Map<String, bool> enabled = <String, bool>{
      for (final LyricsProviderEntry e in _stored(env.prefs)) e.id: e.enabled,
    };
    expect(enabled['server:subsonic-c'], isFalse);
    expect(enabled['server:subsonic-b'], isFalse, reason: '不在场的条目不被改动');
    expect(enabled['server:subsonic-a'], isTrue);

    // 重新启用 b：回到最前、仍隐藏。
    final List<MusicOrderedSource> back = (await tester.runAsync(() async {
      await env.prefs.setMusicSubsonicServers(<SubsonicServerConfig>[
        _subsonic('a'),
        _subsonic('b'),
        _subsonic('c'),
      ]);
      return loadOrderedMusicOnlineSources(env.app);
    }))!;
    expect(back.first.source.key, 'server:subsonic-b');
    expect(back.first.enabled, isFalse);
    await _teardown(tester);
  });

  testWidgets('推荐「全部」：换数据源（如 Apple Music 换地区）后服务器那排专辑按新来源重新拉取', (
    WidgetTester tester,
  ) async {
    final _Env env = await _env(tester);
    final _FakeBrowser jp = _FakeBrowser('apple-music:jp');
    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: <MusicOnlineSource>[MusicServerOnlineSource(jp)],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Album apple-music:jp'), findsOneWidget);
    expect(jp.listAlbumsCalls, 1);

    final _FakeBrowser us = _FakeBrowser('apple-music:us');
    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: <MusicOnlineSource>[MusicServerOnlineSource(us)],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    expect(us.listAlbumsCalls, 1);
    expect(find.text('Album apple-music:us'), findsOneWidget);
    expect(find.text('Album apple-music:jp'), findsNothing);

    // 同一 serverId、新浏览器实例（连接配置变了）也按新实例重新取。
    final _FakeBrowser us2 = _FakeBrowser('apple-music:us');
    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: <MusicOnlineSource>[MusicServerOnlineSource(us2)],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    expect(us2.listAlbumsCalls, 1);
    await _teardown(tester);
  });

  testWidgets('推荐：选中的来源消失后，chip 与内容一起回到「全部」', (WidgetTester tester) async {
    final _Env env = await _env(tester);
    final _FakeBrowser navi = _FakeBrowser('subsonic-1');
    final String chipKey =
        'music-recommend-source-${musicServerSourceKey(navi)}';
    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: <MusicOnlineSource>[MusicServerOnlineSource(navi)],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(ValueKey<String>(chipKey)));
    await _settle(tester);
    expect(_chipSelected(tester, chipKey), isTrue);
    expect(_chipSelected(tester, 'music-recommend-source-all'), isFalse);

    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: const <MusicOnlineSource>[],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    expect(_chipSelected(tester, 'music-recommend-source-all'), isTrue);
    await _teardown(tester);
  });

  testWidgets('服务器入口：推荐页选中服务器 chip → 内嵌专辑 → 曲目', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    final _Env env = await _env(tester);
    final _FakeBrowser navi = _FakeBrowser('subsonic-1');
    await tester.pumpWidget(
      _host(
        env.app,
        MusicSourcesRecommendView(
          sources: <MusicOnlineSource>[MusicServerOnlineSource(navi)],
          onSourcesChanged: () {},
        ),
      ),
    );
    await _settle(tester);
    // 「全部」里这台服务器一排专辑，「查看全部」切到它。
    expect(find.text('Album subsonic-1'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-recommend-view-all-subsonic-1')),
    );
    await _settle(tester);
    expect(
      _chipSelected(
        tester,
        'music-recommend-source-${musicServerSourceKey(navi)}',
      ),
      isTrue,
    );
    expect(find.text('Album subsonic-1'), findsOneWidget);
    await tester.tap(find.text('Album subsonic-1'));
    await _settle(tester);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    await _teardown(tester);
  });
}
