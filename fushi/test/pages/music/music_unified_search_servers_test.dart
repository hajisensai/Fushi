import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart'
    show MusicPluginManifest, MusicPluginSearchType;
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 统一搜索接入服务器来源（Jellyfin / OpenSubsonic / Apple Music catalog）：来源 chip 有
/// 服务器、结果在插件之后按服务器分段并带服务器名、某台出错只在它那段显示错误行。
class _FakeServer implements MusicServerBrowser {
  _FakeServer({
    required this.serverId,
    required this.displayName,
    this.result = const MusicServerSearchResult(),
    this.error,
  });

  @override
  final String serverId;

  @override
  final String displayName;

  final MusicServerSearchResult result;
  final Error? error;

  /// [search] 被调了几次（每台服务器每个查询只该搜一次）。
  int searchCalls = 0;

  @override
  MusicServerKind get kind => MusicServerKind.subsonic;

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async =>
      const MusicServerPage<MusicServerAlbum>(items: <MusicServerAlbum>[]);

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async =>
      const <MusicServerTrack>[];

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[];

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      const <MusicServerAlbum>[];

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    searchCalls++;
    final Error? e = error;
    if (e != null) throw e;
    return result;
  }

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse('https://example.invalid/${track.id}'),
        transcoded: false,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) => null;

  @override
  void close() {}
}

const MusicPluginManifest _plugin = MusicPluginManifest(
  id: 'moe.example.music',
  name: '示例音乐',
  version: '0.4.0',
  api: 1,
  capabilities: <String>['search'],
  searchTypes: <String>['song'],
  permissions: <String>[],
  networkDomains: <String>[],
);

MusicSearchLocalActions _noLocalActions() => MusicSearchLocalActions(
  albumCard: (BuildContext context, Object _) => const SizedBox.shrink(),
  openAlbum: (_) {},
  openArtist: (_) {},
);

Future<void> _pump(WidgetTester tester, Widget body) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      ),
    ),
  );
}

/// 过防抖 → 哨兵排搜索 → 结果落地。
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump(kMusicSearchDebounce + const Duration(milliseconds: 10));
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final _FakeServer navidrome = _FakeServer(
    serverId: 'subsonic:navi',
    displayName: 'Navidrome',
    result: const MusicServerSearchResult(
      tracks: <MusicServerTrack>[
        MusicServerTrack(
          id: 'tr1',
          title: 'Server Song',
          artist: 'Server Singer',
          codec: 'flac',
          durationMs: 185000,
        ),
      ],
    ),
  );

  testWidgets('来源 chip：插件之后为每台服务器出一个 chip，值是 serverId', (
    WidgetTester tester,
  ) async {
    String? picked = 'unset';
    await _pump(
      tester,
      MusicSearchSourceChips(
        sources: const <MusicPluginManifest>[_plugin],
        servers: <MusicServerBrowser>[navidrome],
        selected: null,
        onSelected: (String? v) => picked = v,
      ),
    );
    await tester.pumpAndSettle();

    final Finder chip = find.byKey(
      const ValueKey<String>('music-search-source-subsonic:navi'),
    );
    expect(chip, findsOneWidget);
    expect(find.text('Navidrome'), findsOneWidget);
    expect(find.text('示例音乐'), findsOneWidget);
    // 服务器 chip 排在插件 chip 之后。
    expect(
      tester.getTopLeft(chip).dx,
      greaterThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey<String>('music-search-source-moe.example.music'),
              ),
            )
            .dx,
      ),
    );

    await tester.tap(chip);
    await tester.pump();
    expect(picked, 'subsonic:navi');
  });

  testWidgets('结果列表歌曲页签：服务器结果成段出现，段标题是服务器名', (WidgetTester tester) async {
    final _FakeServer server = _FakeServer(
      serverId: navidrome.serverId,
      displayName: navidrome.displayName,
      result: navidrome.result,
    );
    await _pump(
      tester,
      MusicSearchResultsView(
        type: MusicPluginSearchType.song,
        query: 'song',
        sources: const <MusicPluginManifest>[],
        servers: <MusicServerBrowser>[server],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
      ),
    );
    await _settleSearch(tester);

    expect(
      find.byKey(
        const ValueKey<String>('music-search-header-server-subsonic:navi'),
      ),
      findsOneWidget,
    );
    expect(find.text('Navidrome'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('music-search-song-server-subsonic:navi-tr1'),
      ),
      findsOneWidget,
    );
    expect(find.text('Server Song'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-search-play-all')),
      findsOneWidget,
    );
    expect(server.searchCalls, 1, reason: '每台服务器每个查询只搜一次、不翻页');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('结果列表：某台服务器出错只在它那段显示错误行，另一台照常', (WidgetTester tester) async {
    final _FakeServer ok = _FakeServer(
      serverId: navidrome.serverId,
      displayName: navidrome.displayName,
      result: navidrome.result,
    );
    final _FakeServer broken = _FakeServer(
      serverId: 'jellyfin:home',
      displayName: 'Home Jellyfin',
      error: StateError('server down'),
    );
    await _pump(
      tester,
      MusicSearchResultsView(
        type: MusicPluginSearchType.song,
        query: 'song',
        sources: const <MusicPluginManifest>[],
        servers: <MusicServerBrowser>[broken, ok],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
      ),
    );
    await _settleSearch(tester);

    expect(
      find.byKey(
        const ValueKey<String>('music-search-server-error-jellyfin:home'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('music-search-server-error-subsonic:navi'),
      ),
      findsNothing,
    );
    expect(find.text('Server Song'), findsOneWidget);
    expect(find.text('Home Jellyfin'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('歌单页签服务器不参与：不发请求、不出服务器段', (WidgetTester tester) async {
    final _FakeServer server = _FakeServer(
      serverId: navidrome.serverId,
      displayName: navidrome.displayName,
      result: navidrome.result,
    );
    await _pump(
      tester,
      MusicSearchResultsView(
        type: MusicPluginSearchType.playlist,
        query: 'song',
        sources: const <MusicPluginManifest>[],
        servers: <MusicServerBrowser>[server],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
      ),
    );
    await _settleSearch(tester);

    expect(find.text('Navidrome'), findsNothing);
    expect(server.searchCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('综合结果：服务器歌曲并进歌曲前 5，行尾来源标签是服务器名', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    final _FakeServer server = _FakeServer(
      serverId: navidrome.serverId,
      displayName: navidrome.displayName,
      result: navidrome.result,
    );
    await _pump(
      tester,
      MusicSearchOverview(
        query: 'song',
        sources: const <MusicPluginManifest>[],
        servers: <MusicServerBrowser>[server],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
        onSeeAll: (_) {},
      ),
    );
    await _settleSearch(tester);

    expect(
      find.byKey(
        const ValueKey<String>('music-search-song-server-subsonic:navi-tr1'),
      ),
      findsOneWidget,
    );
    // 歌曲行尾的来源标签（最佳匹配卡的副行也带服务器名）。
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('music-search-song-server-subsonic:navi-tr1'),
        ),
        matching: find.text('Navidrome'),
      ),
      findsOneWidget,
    );
    expect(server.searchCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
