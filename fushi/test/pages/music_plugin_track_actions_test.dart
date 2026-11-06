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

/// 在线插件的「更多」动作（与 Apple Music 共用 music_track_actions.dart 的菜单与选歌单流程）：
/// 真页面 + 真 [MusicSession] / 引擎，插件源换成记录调用的内存替身。
const String _pluginId = 'ne';
const String _mine = 'mine';
const String _other = 'other';

MusicPluginManifest _manifest() =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': _pluginId,
      'name': 'NE',
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>[
        'search',
        'album',
        'playlist',
        'artist',
        'stream',
        'login',
        'account',
        'like',
        'playlistEdit',
        'radio',
        'collect',
      ],
    });

MusicPluginTrack _track(String id) => MusicPluginTrack(
  id: id,
  title: 'Track $id',
  artists: const <MusicPluginArtistRef>[
    MusicPluginArtistRef(id: 'ar1', name: 'Singer'),
  ],
  albumId: 'al1',
  albumTitle: 'Album',
);

class _Platform implements MusicPluginLikeHost {
  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      <MusicPluginManifest>[_manifest()];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async =>
      const MusicPluginLikes(trackIds: <String>{});

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {}
}

/// 插件源替身：记下每次写操作。
class _Source extends MusicPluginSource {
  _Source(super.manager, super.pluginId, this.log);

  final List<String> log;

  @override
  Future<({MusicPluginPlaylist playlist, List<MusicPluginTrack> tracks})>
  playlist(String id) async {
    log.add('playlist:$id');
    return (
      playlist: MusicPluginPlaylist(
        id: id,
        title: id == _mine ? 'Mine' : 'Other',
        editable: id == _mine,
        collected: id == _mine ? null : false,
      ),
      tracks: <MusicPluginTrack>[_track('1'), _track('2')],
    );
  }

  @override
  Future<MusicPluginPage<MusicPluginPlaylist>> library({
    int page = 0,
    int pageSize = 50,
  }) async => const MusicPluginPage<MusicPluginPlaylist>(
    items: <MusicPluginPlaylist>[
      MusicPluginPlaylist(id: 'liked', title: 'Liked songs'),
      MusicPluginPlaylist(id: 'mine2', title: 'Road trip', editable: true),
    ],
    hasMore: false,
  );

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) async =>
      log.add('add:$playlistId:${trackIds.join(',')}');

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    List<String> trackIds,
  ) async => log.add('remove:$playlistId:${trackIds.join(',')}');

  @override
  Future<MusicPluginRadioBatch> radioNext({
    String? seedTrackId,
    int? count,
  }) async {
    log.add('radio:${seedTrackId ?? '-'}');
    return MusicPluginRadioBatch(
      tracks: <MusicPluginTrack>[_track('r1'), _track('r2'), _track('r3')],
    );
  }

  @override
  Future<void> radioTrash(String trackId) async => log.add('trash:$trackId');

  @override
  Future<void> setCollected(
    MusicPluginCollectType type,
    String id, {
    required bool on,
  }) async => log.add('collect:${type.wire}:$id:$on');
}

class _Manager extends MusicPluginManager {
  _Manager(Directory root)
    : super(
        rootDir: root,
        httpClientFactory: HttpClient.new,
        log: (String _, String __, String ___) {},
      );

  final List<String> log = <String>[];

  @override
  MusicPluginSource source(String id) => _Source(this, id, log);
}

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> opened = <String>[];

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
  }) async => opened.add(current.title);

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
  late _AppModel app;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_plugin_actions_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final MusicPluginFavorites favorites = MusicPluginFavorites(_Platform());
    await favorites.refresh();
    app = _AppModel(
      db: db,
      favorites: favorites,
      manager: _Manager(dir),
      prefs: prefs,
      dir: dir,
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpPlaylist(WidgetTester tester, String id) async {
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
              playlist: MusicPluginPlaylist(id: id, title: id),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTrackMenu(WidgetTester tester, String id) async {
    await tester.tap(
      find.byKey(ValueKey<String>('music-plugin-track-menu-$id')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('自己的歌单：曲目菜单列齐动作，「从这个歌单移除」后重拉', (WidgetTester tester) async {
    await pumpPlaylist(tester, _mine);
    expect(app.manager.log, <String>['playlist:$_mine']);
    await openTrackMenu(tester, '1');
    for (final String label in <String>[
      t.music_action_love,
      t.music_action_dislike,
      t.music_action_add_to_playlist,
      t.music_action_remove_from_playlist,
      t.music_action_start_station,
      t.music_action_go_to_artist,
      t.music_action_go_to_album,
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text(t.music_action_remove_from_playlist));
    await tester.pumpAndSettle();
    expect(app.manager.log, <String>[
      'playlist:$_mine',
      'remove:$_mine:1',
      'playlist:$_mine',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('别人的歌单：没有「移除」；加入歌单只列可编辑的歌单', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await openTrackMenu(tester, '2');
    expect(find.text(t.music_action_remove_from_playlist), findsNothing);
    await tester.tap(find.text(t.music_action_add_to_playlist));
    await tester.pumpAndSettle();
    expect(find.text(t.music_action_new_playlist), findsOneWidget);
    expect(find.text('Road trip'), findsOneWidget);
    expect(find.text('Liked songs'), findsNothing, reason: '不可编辑的不列');
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('add:mine2:2'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('以这首起电台：按种子取一批并开播、来源记成该电台', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await openTrackMenu(tester, '1');
    await tester.tap(find.text(t.music_action_start_station));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('radio:1'));
    final MusicPlayerEngine engine = app.musicSession.engine;
    expect(engine.current?.title, 'Track r1');
    expect(engine.source?.id, 'radio:$_pluginId:1');
    expect(app.musicSession.queueFeeds.activeSource, same(engine.source));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('不喜欢 = 插件的不再推荐', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await openTrackMenu(tester, '2');
    await tester.tap(find.text(t.music_action_dislike));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('trash:2'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('歌单「更多」：未收藏只给「收藏」，收藏后改成只给「取消收藏」', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    final Finder more = find.byKey(
      const ValueKey<String>('music-plugin-collection-more'),
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text(t.music_action_uncollect), findsNothing);
    await tester.tap(find.text(t.music_action_collect));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('collect:playlist:$_other:true'));

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text(t.music_action_collect), findsNothing);
    expect(find.text(t.music_action_uncollect), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自己的歌单「更多」：只有删除（不出收藏）', (WidgetTester tester) async {
    await pumpPlaylist(tester, _mine);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-plugin-collection-more')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.music_action_delete_playlist), findsOneWidget);
    expect(find.text(t.music_action_collect), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
