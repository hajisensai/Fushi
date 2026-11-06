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
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 歌单详情页（[MusicPluginCollectionPage]）打开的是插件账号的「喜欢」歌单时，喜欢 /
/// 取消喜欢一首后要按喜欢集合修订号重拉曲目（`_onFavoritesChanged`）。
///
/// 真 [MusicPluginFavorites]（插件侧换成内存替身）、真 [MusicSession]、真页面；插件源
/// 的 `playlist` 按替身里的喜欢集合现算曲目，所以列表变化来自真实的重拉，而不是测试
/// 直接改 UI 数据。
const String _pluginId = 'ne';
const String _likedPlaylistId = 'fav-ne';

MusicPluginManifest _manifest() =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': _pluginId,
      'name': 'NE',
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>['search', 'login', 'account', 'like'],
    });

MusicPluginTrack _track(String id) =>
    MusicPluginTrack(id: id, title: 'Track $id', artists: const []);

/// 平台账号侧：喜欢集合 + 喜欢 / 取消喜欢。
class _Platform implements MusicPluginLikeHost {
  final Set<String> liked = <String>{'1'};

  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      <MusicPluginManifest>[_manifest()];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async => MusicPluginLikes(
    trackIds: <String>{...liked},
    playlist: const MusicPluginPlaylist(id: _likedPlaylistId, title: 'Liked'),
  );

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {
    liked ? this.liked.add(trackId) : this.liked.remove(trackId);
  }
}

/// 插件源：`playlist(id)` 的结果取自平台当前状态（喜欢歌单 = 喜欢集合）。
class _Source extends MusicPluginSource {
  _Source(super.manager, super.pluginId, this.platform, this.calls);

  final _Platform platform;
  final List<String> calls;

  @override
  Future<({MusicPluginPlaylist playlist, List<MusicPluginTrack> tracks})>
  playlist(String id) async {
    calls.add(id);
    final List<String> ids = id == _likedPlaylistId
        ? (platform.liked.toList()..sort())
        : <String>['9'];
    return (
      playlist: MusicPluginPlaylist(id: id, title: 'Liked'),
      tracks: <MusicPluginTrack>[for (final String t in ids) _track(t)],
    );
  }
}

class _Manager extends MusicPluginManager {
  _Manager(this.platform, Directory root)
    : super(
        rootDir: root,
        httpClientFactory: HttpClient.new,
        log: (String _, String __, String ___) {},
      );

  final _Platform platform;
  final List<String> playlistCalls = <String>[];

  @override
  MusicPluginSource source(String id) =>
      _Source(this, id, platform, playlistCalls);
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
  late FushiDatabase db;
  late Directory dir;
  late _Platform platform;
  late MusicPluginFavorites favorites;
  late _AppModel app;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_plugin_collection_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    platform = _Platform();
    favorites = MusicPluginFavorites(platform);
    await favorites.refresh();
    app = _AppModel(
      db: db,
      favorites: favorites,
      manager: _Manager(platform, dir),
      prefs: prefs,
      dir: dir,
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester, String playlistId) async {
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
            home: MusicPluginCollectionPage.playlist(
              manifest: _manifest(),
              playlist: MusicPluginPlaylist(id: playlistId, title: 'Liked'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder trackRow(String id) =>
      find.byKey(ValueKey<String>('music-plugin-track-$id'));

  testWidgets('喜欢歌单：喜欢 / 取消喜欢后按修订号重拉曲目，列表跟着变', (WidgetTester tester) async {
    await pumpPage(tester, _likedPlaylistId);
    expect(app.manager.playlistCalls, <String>[_likedPlaylistId]);
    expect(trackRow('1'), findsOneWidget);
    expect(trackRow('2'), findsNothing);

    unawaited(favorites.toggle(musicPluginPlayItem(_pluginId, _track('2'))));
    await tester.pumpAndSettle();
    expect(app.manager.playlistCalls, <String>[
      _likedPlaylistId,
      _likedPlaylistId,
    ], reason: '喜欢集合修订号变了：喜欢歌单要重拉');
    expect(trackRow('2'), findsOneWidget, reason: '新喜欢的歌出现在列表里');

    unawaited(favorites.toggle(musicPluginPlayItem(_pluginId, _track('1'))));
    await tester.pumpAndSettle();
    expect(app.manager.playlistCalls, hasLength(3));
    expect(trackRow('1'), findsNothing, reason: '取消喜欢的歌从列表消失');
    expect(trackRow('2'), findsOneWidget);

    // 重拉到相同内容不算变化：修订号不动，不白白重拉。
    unawaited(favorites.refreshPlugin(_pluginId));
    await tester.pumpAndSettle();
    expect(app.manager.playlistCalls, hasLength(3));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普通歌单：喜欢集合变化不触发重拉', (WidgetTester tester) async {
    await pumpPage(tester, 'other');
    expect(app.manager.playlistCalls, <String>['other']);
    expect(trackRow('9'), findsOneWidget);

    unawaited(favorites.toggle(musicPluginPlayItem(_pluginId, _track('2'))));
    await tester.pumpAndSettle();
    expect(app.manager.playlistCalls, <String>['other']);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
