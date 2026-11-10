import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 xEZEPAqZq3：插件音源首页的歌单 / 专辑栏目要有「查看全部」——横排只列前
/// [kMusicPluginShelfPreview] 张，点「查看全部」进网格页看该栏目的完整列表，点卡片
/// 仍进专辑 / 歌单详情（与服务器来源那一排 `_ServerShelf` 同一形态）。
///
/// 真 [MusicPluginRecommendView]、真推荐页段落布局；插件源只把 `home()` / `album()`
/// 换成固定数据。
const String _pluginId = 'asmr';
const String _albumSectionId = 'new-albums';
const String _playlistSectionId = 'hot-playlists';

/// 第一个曲目段被推荐页拿去做主卡（`_RecommendHero.tracks`，自带播放），不出段落头；
/// 第二个曲目段才走普通段落头，验证它仍是「播放全部」而不是「查看全部」。
const String _heroTrackSectionId = 'hero-tracks';
const String _trackSectionId = 'daily';
const int _albumCount = 20;

MusicPluginManifest _manifest() =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': _pluginId,
      'name': 'ASMR',
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>['search', 'home'],
    });

MusicPluginAlbum _album(int i) =>
    MusicPluginAlbum(id: 'a$i', title: 'Album $i');

MusicPluginPlaylist _playlist(int i) =>
    MusicPluginPlaylist(id: 'p$i', title: 'Playlist $i');

final List<MusicPluginHomeSection> _sections = <MusicPluginHomeSection>[
  MusicPluginHomeSection(
    id: _heroTrackSectionId,
    title: 'For you',
    kind: MusicPluginHomeKind.tracks,
    items: <Object>[
      for (int i = 0; i < 3; i++)
        MusicPluginTrack(id: 'h$i', title: 'Hero $i', artists: const []),
    ],
  ),
  MusicPluginHomeSection(
    id: _trackSectionId,
    title: 'Daily',
    kind: MusicPluginHomeKind.tracks,
    items: <Object>[
      for (int i = 0; i < 3; i++)
        MusicPluginTrack(id: 't$i', title: 'Track $i', artists: const []),
    ],
  ),
  MusicPluginHomeSection(
    id: _albumSectionId,
    title: 'New albums',
    kind: MusicPluginHomeKind.albums,
    items: <Object>[for (int i = 0; i < _albumCount; i++) _album(i)],
  ),
  MusicPluginHomeSection(
    id: _playlistSectionId,
    title: 'Hot playlists',
    kind: MusicPluginHomeKind.playlists,
    items: <Object>[for (int i = 0; i < 3; i++) _playlist(i)],
  ),
];

class _NoLikes implements MusicPluginLikeHost {
  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      const <MusicPluginManifest>[];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async => null;

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {}
}

class _Source extends MusicPluginSource {
  _Source(super.manager, super.pluginId, this.albumCalls);

  final List<String> albumCalls;

  @override
  Future<List<MusicPluginHomeSection>> home({bool refresh = false}) async =>
      _sections;

  @override
  Future<({MusicPluginAlbum album, List<MusicPluginTrack> tracks})> album(
    String id,
  ) async {
    albumCalls.add(id);
    return (
      album: MusicPluginAlbum(id: id, title: 'Album $id'),
      tracks: const <MusicPluginTrack>[],
    );
  }
}

class _Manager extends MusicPluginManager {
  _Manager(Directory root)
    : super(
        rootDir: root,
        httpClientFactory: HttpClient.new,
        log: (String _, String __, String ___) {},
      );

  final List<String> albumCalls = <String>[];

  @override
  MusicPluginSource source(String id) => _Source(this, id, albumCalls);
}

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

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
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

class _AppModel extends AppModel {
  _AppModel({
    required this.db,
    required this.favorites,
    required this.manager,
    required PreferencesRepository prefs,
    required Directory dir,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
  }

  final FushiDatabase db;
  final MusicPluginFavorites favorites;
  final _Manager manager;
  final _Backend backend = _Backend();

  late final MusicSession _session = MusicSession(
    engine: MusicPlayerEngine(backendFactory: () => backend),
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
    favorites: favorites,
  );

  @override
  MusicSession get musicSession => _session;

  @override
  MusicPluginManager get musicPluginManager => manager;
}

void main() {
  group('musicPluginShelfPreview', () {
    test('超过上限只留前 kMusicPluginShelfPreview 个，顺序不变', () {
      final List<Object> items = <Object>[
        for (int i = 0; i < _albumCount; i++) _album(i),
      ];
      final List<Object> preview = musicPluginShelfPreview(items);
      expect(preview, hasLength(kMusicPluginShelfPreview));
      expect(preview, items.take(kMusicPluginShelfPreview).toList());
    });

    test('不超过上限原样返回', () {
      final List<Object> items = <Object>[
        for (int i = 0; i < 3; i++) _album(i),
      ];
      expect(musicPluginShelfPreview(items), same(items));
    });
  });

  group('推荐页插件栏目「查看全部」', () {
    late FushiDatabase db;
    late Directory dir;
    late _AppModel app;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('fushi_plugin_view_all_');
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      app = _AppModel(
        db: db,
        favorites: MusicPluginFavorites(_NoLikes()),
        manager: _Manager(dir),
        prefs: prefs,
        dir: dir,
      );
    });

    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    Future<void> pumpRecommend(WidgetTester tester) async {
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
              home: Scaffold(
                body: MusicPluginRecommendView(
                  sources: <MusicPluginManifest>[_manifest()],
                  showPersonal: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder viewAll(String sectionId) => find.byKey(
      ValueKey<String>('music-plugin-home-view-all-$_pluginId-$sectionId'),
    );

    Finder gridCard(String id) =>
        find.byKey(ValueKey<String>('music-plugin-grid-card-$id'));

    testWidgets('歌单 / 专辑栏目有「查看全部」，曲目栏目仍是「播放全部」', (WidgetTester tester) async {
      await pumpRecommend(tester);

      // 推荐页是懒构建的 ListView：每个断言前先把目标段落滚进视口，滚过头的段落
      // 会被回收，不能在滚到底之后再回头断言上面的段落。
      Future<void> scrollTo(Finder target) => tester.scrollUntilVisible(
        target,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('music-plugin-recommend')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      final Finder playTracks = find.byKey(
        const ValueKey<String>(
          'music-plugin-home-play-$_pluginId-$_trackSectionId',
        ),
      );
      await scrollTo(playTracks);
      expect(playTracks, findsOneWidget);
      expect(viewAll(_trackSectionId), findsNothing);
      expect(viewAll(_heroTrackSectionId), findsNothing);

      await scrollTo(viewAll(_albumSectionId));
      expect(viewAll(_albumSectionId), findsOneWidget);

      await scrollTo(viewAll(_playlistSectionId));
      expect(viewAll(_playlistSectionId), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('点「查看全部」进网格页，列出栏目全部条目，点卡片进专辑详情', (WidgetTester tester) async {
      await pumpRecommend(tester);

      await tester.scrollUntilVisible(
        viewAll(_albumSectionId),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('music-plugin-recommend')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(viewAll(_albumSectionId));
      await tester.pumpAndSettle();

      expect(find.byType(MusicPluginHomeSectionPage), findsOneWidget);
      final Finder grid = find.byKey(
        const ValueKey<String>(
          'music-plugin-section-grid-$_pluginId-$_albumSectionId',
        ),
      );
      expect(grid, findsOneWidget);
      final Finder gridScrollable = find
          .descendant(of: grid, matching: find.byType(Scrollable))
          .first;

      // 横排只到第 12 张；网格里第 20 张（超出横排上限的那部分）也在。
      const String lastId = 'album-a${_albumCount - 1}';
      await tester.scrollUntilVisible(
        gridCard(lastId),
        300,
        scrollable: gridScrollable,
      );
      // scrollUntilVisible 在卡片落进缓存区（已构建、仍在视口外）时就停，这里再把它
      // 完整滚进视口，点击才命中卡片本身。
      await tester.ensureVisible(gridCard(lastId));
      await tester.pumpAndSettle();
      expect(gridCard(lastId), findsOneWidget);

      await tester.tap(gridCard(lastId));
      await tester.pumpAndSettle();
      expect(find.byType(MusicPluginCollectionPage), findsOneWidget);
      expect(app.manager.albumCalls, <String>['a${_albumCount - 1}']);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
