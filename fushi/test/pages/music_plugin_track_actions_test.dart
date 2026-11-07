import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
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
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show musicPluginTrackPath, musicPluginTrackUid;
import 'package:fushi/src/utils/app_ui_scale.dart';
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

  // 同一个容器跨 pump 保留（收藏状态要能从卡片带到歌单页）。
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
    );
  });
  tearDown(() => container.dispose());

  /// 挂 [home]；[uiScale] 是全局界面大小（与 main.dart 同拓扑：[FushiAppUiScale]
  /// 挂在 `MaterialApp.builder`，包住 Navigator / Overlay）。
  Future<void> pumpHome(
    WidgetTester tester,
    Widget home, {
    double uiScale = 1,
  }) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: FushiAppUiScale(scale: uiScale, child: child!),
            ),
            home: home,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpPlaylist(WidgetTester tester, String id) => pumpHome(
    tester,
    MusicPluginCollectionPage.playlist(
      manifest: _manifest(),
      playlist: MusicPluginPlaylist(id: id, title: id),
    ),
  );

  /// 插件条目行（搜索 / 推荐 / 我的歌单共用的 [musicPluginItemTile]）。
  Widget itemTiles(List<Object> items) => Scaffold(
    body: Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) => ListView(
        children: <Widget>[
          for (int i = 0; i < items.length; i++)
            musicPluginItemTile(context, ref, _manifest(), items, i),
        ],
      ),
    ),
  );

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    await tester.tap(
      target,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Finder menuAction(String id) =>
      find.byKey(ValueKey<String>('music-menu-action-$id'));

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

  testWidgets('曲目整行右键弹同一份菜单（下拉，不是居中面板）', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-plugin-track-2')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('music-menu-action-dislike')),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsNothing, reason: '菜单是锚定下拉，不是对话框');
    await tester.tap(find.text(t.music_action_dislike));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('trash:2'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('歌单「收藏」平铺在按钮行：点一下收藏，再点取消', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    expect(
      find.byKey(const ValueKey<String>('music-plugin-collection-more')),
      findsNothing,
      reason: '收藏不再收进「更多」',
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('music-plugin-collection-collect'),
    );
    expect(
      find.descendant(of: toggle, matching: find.text(t.music_action_collect)),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('collect:playlist:$_other:true'));
    expect(
      find.descendant(
        of: toggle,
        matching: find.text(t.music_action_collected),
      ),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('collect:playlist:$_other:false'));
    expect(
      find.descendant(of: toggle, matching: find.text(t.music_action_collect)),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自己的歌单：按钮行给「删除歌单」，不出收藏', (WidgetTester tester) async {
    await pumpPlaylist(tester, _mine);
    expect(
      find.byKey(const ValueKey<String>('music-plugin-playlist-delete')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music-plugin-collection-collect')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('歌单行右键收藏后再右键变成「取消收藏」，进歌单页按钮也是已收藏', (WidgetTester tester) async {
    await pumpHome(
      tester,
      itemTiles(const <Object>[
        MusicPluginPlaylist(id: _other, title: 'Other', collected: false),
      ]),
    );
    final Finder row = find.byKey(
      const ValueKey<String>('music-plugin-playlist-$_other'),
    );
    await rightClick(tester, row);
    expect(menuAction('open'), findsOneWidget);
    expect(menuAction('collect'), findsOneWidget);
    expect(menuAction('uncollect'), findsNothing, reason: '快照是未收藏');
    await tester.tap(menuAction('collect'));
    await tester.pumpAndSettle();
    expect(app.manager.log, <String>['collect:playlist:$_other:true']);

    // 条目快照仍是 collected: false；菜单要跟着这次收藏走，不能还给「收藏」。
    await rightClick(tester, row);
    expect(menuAction('collect'), findsNothing);
    expect(menuAction('uncollect'), findsOneWidget);
    await tester.tap(menuAction('uncollect'));
    await tester.pumpAndSettle();
    expect(app.manager.log.last, 'collect:playlist:$_other:false');
    await rightClick(tester, row);
    expect(menuAction('collect'), findsOneWidget);
    expect(menuAction('uncollect'), findsNothing);
    await tester.tap(menuAction('collect'));
    await tester.pumpAndSettle();

    // 卡片上收藏过，歌单页（插件给的快照仍是未收藏）的切换按钮也要是已收藏。
    await pumpPlaylist(tester, _other);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('music-plugin-collection-collect'),
        ),
        matching: find.text(t.music_action_collected),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('歌单页按钮收藏后，回到列表右键也是「取消收藏」', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-plugin-collection-collect')),
    );
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('collect:playlist:$_other:true'));
    await pumpHome(
      tester,
      itemTiles(const <Object>[
        MusicPluginPlaylist(id: _other, title: 'Other', collected: false),
      ]),
    );
    await rightClick(
      tester,
      find.byKey(const ValueKey<String>('music-plugin-playlist-$_other')),
    );
    expect(menuAction('collect'), findsNothing);
    expect(menuAction('uncollect'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自己的歌单行右键：只有「打开」，不出收藏', (WidgetTester tester) async {
    await pumpHome(
      tester,
      itemTiles(const <Object>[
        MusicPluginPlaylist(id: _mine, title: 'Mine', editable: true),
      ]),
    );
    await rightClick(
      tester,
      find.byKey(const ValueKey<String>('music-plugin-playlist-$_mine')),
    );
    expect(menuAction('open'), findsOneWidget);
    expect(menuAction('collect'), findsNothing);
    expect(menuAction('uncollect'), findsNothing);
    await tester.tap(menuAction('open'));
    await tester.pumpAndSettle();
    expect(app.manager.log, contains('playlist:$_mine'), reason: '打开 = 进歌单页');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('专辑行右键：收藏未知时两项都给，「去艺人」带艺人名', (WidgetTester tester) async {
    await pumpHome(
      tester,
      itemTiles(const <Object>[
        MusicPluginAlbum(
          id: 'al9',
          title: 'Album 9',
          artists: <MusicPluginArtistRef>[
            MusicPluginArtistRef(id: 'ar1', name: 'Singer'),
          ],
        ),
      ]),
    );
    await rightClick(
      tester,
      find.byKey(const ValueKey<String>('music-plugin-album-al9')),
    );
    expect(menuAction('collect'), findsOneWidget);
    expect(menuAction('uncollect'), findsOneWidget);
    expect(
      find.descendant(of: menuAction('artist'), matching: find.text('Singer')),
      findsOneWidget,
    );
    await tester.tap(menuAction('collect'));
    await tester.pumpAndSettle();
    expect(app.manager.log, <String>['collect:album:al9:true']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('界面大小 ≠ 100% 时右键菜单贴着指针弹（锚点经 Overlay 换算）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHome(
      tester,
      itemTiles(<Object>[
        for (int i = 0; i < 8; i++)
          MusicPluginPlaylist(id: 'p$i', title: 'P$i'),
      ]),
      uiScale: 1.5,
    );
    // 屏幕中部的一行：离原点够远，漏了换算会差出 (scale - 1) 倍坐标（几百像素）。
    final Offset click = tester.getCenter(
      find.byKey(const ValueKey<String>('music-plugin-playlist-p3')),
    );
    await tester.tapAt(
      click,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final Rect item = tester.getRect(menuAction('open'));
    // 画布右下都有余量，菜单左上角就落在指针处；第一项只差菜单的内边距。
    // 漏了换算会落在「指针 × 1.5」，差出几百像素。
    expect(
      (item.topLeft - click).distance,
      lessThan(40),
      reason: 'click=$click item=$item',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('本地曲目列表整行右键：播放 / 曲目详情；不加行尾「⋯」', (WidgetTester tester) async {
    const MusicTrackRow track = MusicTrackRow(
      trackUid: 'lt1',
      path: '/m/local.flac',
      title: 'Local One',
      isLossless: true,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );
    await pumpHome(
      tester,
      const Scaffold(
        body: MusicTrackList(
          tracks: <MusicTrackRow>[track],
          albums: <String, MusicAlbumRow>{},
          context: MusicQueueContext.mixed,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('music-track-menu-lt1')),
      findsNothing,
    );
    await rightClick(
      tester,
      find.byKey(const ValueKey<String>('music-track-lt1')),
    );
    expect(menuAction('play'), findsOneWidget);
    expect(menuAction('detail'), findsOneWidget);
    await tester.tap(menuAction('play'));
    await tester.pumpAndSettle();
    expect(app.musicSession.engine.current?.title, 'Local One');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ── 远程曲目加入音乐库 / 本地歌单（v147，反馈 0tRY-D2JgG）──

  testWidgets('插件曲目菜单：加入音乐库 → 落远程曲目行；再开菜单变成「从音乐库移除」', (
    WidgetTester tester,
  ) async {
    await pumpPlaylist(tester, _other);
    await openTrackMenu(tester, '1');
    expect(menuAction('addToLocalPlaylist'), findsOneWidget);
    expect(find.text(t.music_action_add_to_local_playlist), findsOneWidget);
    await tester.tap(menuAction('addToLibrary'));
    await tester.pumpAndSettle();
    final MusicRemoteTrackRow row = (await db.getMusicRemoteTrack(
      musicPluginTrackUid(_pluginId, '1'),
    ))!;
    expect(row.kind, 'plugin');
    expect(row.sourceKey, _pluginId);
    expect(row.itemId, '1');
    expect(row.title, 'Track 1');
    expect(row.libraryAddedAt, isNotNull);

    await openTrackMenu(tester, '1');
    expect(menuAction('addToLibrary'), findsNothing);
    await tester.tap(menuAction('removeFromLibrary'));
    await tester.pumpAndSettle();
    expect(
      (await db.getMusicRemoteTrack(
        musicPluginTrackUid(_pluginId, '1'),
      ))?.libraryAddedAt,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('插件曲目菜单「加入本地歌单」→ 新建歌单：条目与远程曲目行同时落库', (WidgetTester tester) async {
    await pumpPlaylist(tester, _other);
    await openTrackMenu(tester, '2');
    await tester.tap(menuAction('addToLocalPlaylist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.music_action_new_playlist));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Road');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final MusicPlaylistRow p = (await db.listMusicPlaylists()).single;
    expect(p.name, 'Road');
    final List<MusicPlaylistEntryRow> entries = await db
        .listMusicPlaylistEntries(p.playlistUid);
    expect(entries.single.trackUid, musicPluginTrackUid(_pluginId, '2'));
    final MusicRemoteTrackRow row = (await db.getMusicRemoteTrack(
      musicPluginTrackUid(_pluginId, '2'),
    ))!;
    expect(row.libraryAddedAt, isNull, reason: '加进歌单不等于加入音乐库');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('混排曲目列表：远程曲目行带「⋯」菜单，点行以整列为队列从这首起播', (WidgetTester tester) async {
    const MusicTrackRow local = MusicTrackRow(
      trackUid: 'lt1',
      path: '/m/local.flac',
      title: 'Local One',
      isLossless: true,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );
    final String uid = musicPluginTrackUid(_pluginId, '9');
    final MusicRemoteTrackRow remote = MusicRemoteTrackRow(
      trackUid: uid,
      kind: 'plugin',
      sourceKey: _pluginId,
      itemId: '9',
      title: 'Remote Nine',
      artist: 'Singer',
      libraryAddedAt: 5,
      createdAt: 5,
      updatedAt: 5,
    );
    await pumpHome(
      tester,
      Scaffold(
        body: MusicTrackList.entries(
          entries: <MusicLibraryEntry>[
            const MusicLocalEntry(local),
            MusicRemoteEntry(remote),
          ],
          albums: const <String, MusicAlbumRow>{},
          context: MusicQueueContext.mixed,
        ),
      ),
    );
    expect(find.text('Singer · $_pluginId'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey<String>('music-track-$uid')));
    await tester.pumpAndSettle();
    final MusicPlayerEngine engine = app.musicSession.engine;
    expect(engine.current?.title, 'Remote Nine');
    expect(engine.current?.trackUid, uid);
    expect(engine.current?.path, musicPluginTrackPath(_pluginId, '9'));
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'lt1',
      uid,
    ]);

    await tester.tap(
      find.byKey(ValueKey<String>('music-remote-track-menu-$uid')),
    );
    await tester.pumpAndSettle();
    expect(menuAction('play'), findsOneWidget);
    expect(menuAction('removeFromLibrary'), findsOneWidget);
    expect(menuAction('addToLocalPlaylist'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
