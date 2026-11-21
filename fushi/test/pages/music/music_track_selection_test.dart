import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart'
    show MusicViewKind, MusicViewStyle, MusicViewStyleStore;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart'
    show MusicTrackBlock;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 曲目列表多选（拍板台 IDeN5PYaI7，反馈 IDeN5PYaI7）：菜单「多选」进入、点行勾选、底部
/// 动作条的批量动作真落库；本地曲目「从音乐库移除」写墓碑并可撤销。
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
    required PreferencesRepository prefs,
    required Directory dir,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
  }

  final FushiDatabase db;

  late final MusicSession _session = MusicSession(
    engine: MusicPlayerEngine(backendFactory: _Backend.new),
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  @override
  MusicSession get musicSession => _session;
}

MusicTracksCompanion _track(String uid) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'Song $uid',
  artistCredit: const Value<String?>('Singer'),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _AppModel app;
  late ProviderContainer container;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_music_selection_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(db: db, prefs: prefs, dir: dir);
    container = ProviderContainer(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
    );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[_track('a'), _track('b'), _track('c')],
        albums: const <MusicAlbumsCompanion>[],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpList(
    WidgetTester tester,
    Widget list, {
    bool eink = false,
  }) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
            ),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(body: list),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<List<MusicTrackRow>> tracks() async => (await db.listMusicTracks())
    ..sort(
      (MusicTrackRow x, MusicTrackRow y) => x.trackUid.compareTo(y.trackUid),
    );

  Finder menuAction(String id) =>
      find.byKey(ValueKey<String>('music-menu-action-$id'));

  Finder bar() => find.byKey(const ValueKey<String>('music-selection-bar'));

  /// 整行右键开菜单，点「多选」：进入多选并选中这一行。
  Future<void> selectViaMenu(WidgetTester tester, Finder row) async {
    await tester.tap(
      row,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final Finder select = menuAction('select');
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
  }

  Set<String> liveUids(List<MusicTrackRow> rows) => <String>{
    for (final MusicTrackRow r in rows) r.trackUid,
  };

  testWidgets('菜单「多选」进入；点行只勾选不起播；批量从音乐库移除写墓碑，撤销放回', (
    WidgetTester tester,
  ) async {
    await pumpList(
      tester,
      MusicTrackList(
        tracks: await tracks(),
        albums: const <String, MusicAlbumRow>{},
        context: MusicQueueContext.mixed,
      ),
    );
    expect(bar(), findsNothing, reason: '没进多选前不挂动作条');

    await selectViaMenu(
      tester,
      find.byKey(const ValueKey<String>('music-track-a')),
    );
    expect(bar(), findsOneWidget);
    expect(find.text(t.music_selection_count(n: 1)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('music-track-c')));
    await tester.pumpAndSettle();
    expect(find.text(t.music_selection_count(n: 2)), findsOneWidget);
    expect(app.musicSession.engine.current, isNull, reason: '多选态点行不起播');

    // 歌曲视图（不在歌单页）没有「从歌单移除」。
    expect(
      find.byKey(
        const ValueKey<String>('music-selection-remove-from-playlist'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('music-selection-remove-from-library')),
    );
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks()), <String>{'b'});
    expect((await db.getMusicTrack('a'))!.hiddenAt, isNotNull);
    expect((await db.getMusicTrack('c'))!.hiddenAt, isNotNull);
    expect(bar(), findsNothing, reason: '批量动作跑完退出多选，动作条收起');

    await tester.tap(find.byKey(const ValueKey<String>('music-undo-action')));
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks()), <String>{'a', 'b', 'c'});
    expect((await db.getMusicTrack('a'))!.hiddenAt, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全选后「加入队列」：按列表顺序整批入队', (WidgetTester tester) async {
    await pumpList(
      tester,
      MusicTrackList(
        tracks: await tracks(),
        albums: const <String, MusicAlbumRow>{},
        context: MusicQueueContext.mixed,
      ),
    );
    await selectViaMenu(
      tester,
      find.byKey(const ValueKey<String>('music-track-b')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('music-selection-all')));
    await tester.pumpAndSettle();
    expect(find.text(t.music_selection_count(n: 3)), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-selection-add-to-queue')),
    );
    await tester.pumpAndSettle();
    final MusicPlayerEngine engine = app.musicSession.engine;
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'c',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('单首菜单「从音乐库移除」：本地曲目写墓碑', (WidgetTester tester) async {
    await pumpList(
      tester,
      MusicTrackList(
        tracks: await tracks(),
        albums: const <String, MusicAlbumRow>{},
        context: MusicQueueContext.mixed,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('music-track-b')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final Finder remove = menuAction('removeFromLibrary');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks()), <String>{'a', 'c'});
    expect((await db.getMusicTrack('b'))!.hiddenAt, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('歌单页：同一首出现两次只删勾的那几条；撤销按原位置放回；不出「从音乐库移除」', (
    WidgetTester tester,
  ) async {
    final MusicPlaylistRow p = await db.createMusicPlaylist(
      'Road',
      at: 1,
      trackUids: <String>['a', 'b', 'a'],
    );
    final List<MusicPlaylistEntryRow> rows = await db.listMusicPlaylistEntries(
      p.playlistUid,
    );
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow r in await tracks()) r.trackUid: r,
    };
    await pumpList(
      tester,
      MusicTrackList.entries(
        entries: <MusicLibraryEntry>[
          for (final MusicPlaylistEntryRow r in rows)
            MusicLocalEntry(byUid[r.trackUid]!),
        ],
        albums: const <String, MusicAlbumRow>{},
        context: MusicQueueContext.mixed,
        playlist: MusicTrackListPlaylist(
          playlist: p,
          entryIds: <int>[for (final MusicPlaylistEntryRow r in rows) r.id],
        ),
      ),
    );
    await selectViaMenu(
      tester,
      find.byKey(const ValueKey<String>('music-track-0-a')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('music-track-1-b')));
    await tester.pumpAndSettle();
    expect(find.text(t.music_selection_count(n: 2)), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-selection-remove-from-library')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('music-selection-remove-from-playlist'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await db.listMusicPlaylistEntries(
        p.playlistUid,
      )).map((MusicPlaylistEntryRow r) => r.id),
      <int>[rows[2].id],
      reason: '只删勾的第 1、2 行，第 3 行（同一首 a）留着',
    );
    expect(liveUids(await db.listMusicTracks()), <String>{'a', 'b', 'c'});

    await tester.tap(find.byKey(const ValueKey<String>('music-undo-action')));
    await tester.pumpAndSettle();
    expect(
      (await db.listMusicPlaylistEntries(
        p.playlistUid,
      )).map((MusicPlaylistEntryRow r) => r.id),
      rows.map((MusicPlaylistEntryRow r) => r.id),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // PR #3620 遗留：本地曲目行原来只能右键开菜单，触屏在歌曲 / 艺人 / 歌单页进不了多选、
  // 也点不到「从歌单移除」。行尾补「⋯」后触屏点它打开同一份菜单（重设计行与 eink 旧行）。
  for (final bool eink in <bool>[false, true]) {
    testWidgets('触屏：歌单页本地曲目行尾「⋯」开菜单，有多选与从歌单移除（eink=$eink）', (
      WidgetTester tester,
    ) async {
      final MusicPlaylistRow p = await db.createMusicPlaylist(
        'Touch',
        at: 1,
        trackUids: <String>['a', 'b'],
      );
      final List<MusicPlaylistEntryRow> rows = await db
          .listMusicPlaylistEntries(p.playlistUid);
      final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
        for (final MusicTrackRow r in await tracks()) r.trackUid: r,
      };
      await pumpList(
        tester,
        MusicTrackList.entries(
          entries: <MusicLibraryEntry>[
            for (final MusicPlaylistEntryRow r in rows)
              MusicLocalEntry(byUid[r.trackUid]!),
          ],
          albums: const <String, MusicAlbumRow>{},
          context: MusicQueueContext.mixed,
          playlist: MusicTrackListPlaylist(
            playlist: p,
            entryIds: <int>[for (final MusicPlaylistEntryRow r in rows) r.id],
          ),
        ),
        eink: eink,
      );
      final Finder more = find.byKey(
        const ValueKey<String>('music-track-menu-b'),
      );
      expect(more, findsOneWidget, reason: '本地曲目行尾要有「⋯」');
      await tester.tap(more); // 默认触屏指针。
      await tester.pumpAndSettle();
      expect(menuAction('select'), findsOneWidget);
      final Finder remove = menuAction('removeFromPlaylist');
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(
        (await db.listMusicPlaylistEntries(
          p.playlistUid,
        )).map((MusicPlaylistEntryRow r) => r.trackUid),
        <String>['a'],
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('专辑页：跨碟多选（菜单进入、长按勾选）；批量从音乐库移除写墓碑，撤销放回；单首菜单可移除', (
    WidgetTester tester,
  ) async {
    // 专辑页 hero 高：默认 800×600 下第二碟落在首屏以下（懒构建），放大视口让两碟都在。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    MusicTracksCompanion albumTrack(String uid, int disc, int no) =>
        _track(uid).copyWith(
          albumUid: const Value<String?>('al'),
          discNo: Value<int?>(disc),
          trackNo: Value<int?>(no),
        );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          albumTrack('d1', 1, 1),
          albumTrack('d2', 1, 2),
          albumTrack('e1', 2, 1),
        ],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'al',
            title: 'Night Album',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    final MusicAlbumRow album = (await db.getMusicAlbum('al'))!;
    final List<MusicTrackRow> albumTracks = sortAlbumTracks(
      await db.listMusicTracks(albumUid: 'al'),
    );
    await pumpList(tester, MusicAlbumPage(album: album, tracks: albumTracks));
    Finder row(String uid) =>
        find.byKey(ValueKey<String>('music-album-track-$uid'));
    expect(bar(), findsNothing);

    await selectViaMenu(tester, row('d1'));
    expect(bar(), findsOneWidget);
    expect(find.text(t.music_selection_count(n: 1)), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-album-track-check-d2')),
      findsOneWidget,
      reason: '多选态每行行尾出勾选圈',
    );

    // 第二碟的一首：多选态长按 = 勾选，不起播。
    await tester.longPress(row('e1'));
    await tester.pumpAndSettle();
    expect(find.text(t.music_selection_count(n: 2)), findsOneWidget);
    expect(app.musicSession.engine.current, isNull, reason: '多选态点行不起播');

    await tester.tap(
      find.byKey(const ValueKey<String>('music-selection-remove-from-library')),
    );
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks(albumUid: 'al')), <String>{'d2'});
    expect((await db.getMusicTrack('d1'))!.hiddenAt, isNotNull);
    expect((await db.getMusicTrack('e1'))!.hiddenAt, isNotNull);
    expect(bar(), findsNothing, reason: '批量动作跑完退出多选');
    expect(row('d1'), findsNothing, reason: '专辑页跟着落库重读');

    await tester.tap(find.byKey(const ValueKey<String>('music-undo-action')));
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks(albumUid: 'al')), <String>{
      'd1',
      'd2',
      'e1',
    });

    // 单首菜单「从音乐库移除」。
    await tester.tap(
      row('d2'),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final Finder remove = menuAction('removeFromLibrary');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks(albumUid: 'al')), <String>{
      'd1',
      'e1',
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('专辑页「从音乐库移除」整张专辑：全部写墓碑、退回上一页，撤销放回（拍板台 mmXVwo0Ibv）', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    MusicTracksCompanion albumTrack(String uid, int disc, int no) =>
        _track(uid).copyWith(
          albumUid: const Value<String?>('al'),
          discNo: Value<int?>(disc),
          trackNo: Value<int?>(no),
        );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          albumTrack('d1', 1, 1),
          albumTrack('d2', 1, 2),
          albumTrack('e1', 2, 1),
        ],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'al',
            title: 'Night Album',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    final MusicAlbumRow album = (await db.getMusicAlbum('al'))!;
    final List<MusicTrackRow> albumTracks = sortAlbumTracks(
      await db.listMusicTracks(albumUid: 'al'),
    );
    await pumpList(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          key: const ValueKey<String>('open-album'),
          onPressed: () => unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    MusicAlbumPage(album: album, tracks: albumTracks),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open-album')));
    await tester.pumpAndSettle();
    final Finder remove = find.byKey(
      const ValueKey<String>('music_album_remove'),
    );
    expect(remove, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_disc_remove')),
      findsNothing,
      reason: '普通专辑不出光盘的移除钮',
    );

    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(await db.listMusicTracks(albumUid: 'al'), isEmpty);
    for (final String uid in <String>['d1', 'd2', 'e1']) {
      expect((await db.getMusicTrack(uid))!.hiddenAt, isNotNull, reason: uid);
    }
    expect(
      (await db.listMusicAlbums()).map((MusicAlbumRow a) => a.albumUid),
      isNot(contains('al')),
      reason: '没有在库曲目的专辑不再列在专辑墙',
    );
    expect(find.byType(MusicAlbumPage), findsNothing, reason: '专辑没了退回上一页');
    expect(
      find.byKey(const ValueKey<String>('open-album')),
      findsOneWidget,
      reason: '只退一层，不连退',
    );
    expect(
      find.text(t.music_album_removed_from_library(title: 'Night Album')),
      findsOneWidget,
      reason: '提示写明磁盘文件不动',
    );

    await tester.tap(find.byKey(const ValueKey<String>('music-undo-action')));
    await tester.pumpAndSettle();
    expect(liveUids(await db.listMusicTracks(albumUid: 'al')), <String>{
      'd1',
      'd2',
      'e1',
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 拍板台 left3648（BUG-4769）：色块样式的曲目格没有放「⋯」的位置，触屏长按改成弹与
  // 右键同一份菜单（详情 / 多选都在里面）；多选态长按仍是勾选。
  testWidgets('触屏：色块样式曲目格长按开菜单（有详情与多选），多选态长按 = 勾选', (
    WidgetTester tester,
  ) async {
    await pumpList(
      tester,
      MusicTrackList.entries(
        entries: <MusicLibraryEntry>[
          for (final MusicTrackRow r in await tracks()) MusicLocalEntry(r),
        ],
        albums: const <String, MusicAlbumRow>{},
        context: MusicQueueContext.mixed,
        style: MusicViewStyle.blocks,
      ),
    );
    Finder block(String uid) =>
        find.byKey(ValueKey<String>('music-track-$uid'));
    expect(find.byType(MusicTrackBlock), findsWidgets, reason: '色块样式排色块');
    await tester.longPress(block('a')); // 默认触屏指针。
    await tester.pumpAndSettle();
    expect(menuAction('detail'), findsOneWidget, reason: '详情挪进菜单');
    final Finder select = menuAction('select');
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(bar(), findsOneWidget);
    expect(find.text(t.music_selection_count(n: 1)), findsOneWidget);

    await tester.longPress(block('b'));
    await tester.pumpAndSettle();
    expect(menuAction('select'), findsNothing, reason: '多选态长按不弹菜单');
    expect(find.text(t.music_selection_count(n: 2)), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<MusicAlbumPage> albumPage() async {
    MusicTracksCompanion albumTrack(String uid, int no) => _track(uid).copyWith(
      albumUid: const Value<String?>('al'),
      discNo: const Value<int?>(1),
      trackNo: Value<int?>(no),
    );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          albumTrack('d1', 1),
          albumTrack('d2', 2),
        ],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'al',
            title: 'Night Album',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    return MusicAlbumPage(
      album: (await db.getMusicAlbum('al'))!,
      tracks: sortAlbumTracks(await db.listMusicTracks(albumUid: 'al')),
    );
  }

  // 拍板台 left3648（BUG-4770）：专辑页本地曲目行原来只能右键开菜单，触屏点不到加入
  // 队列 / 加入歌单 / 从音乐库移除。行尾补「⋯」（重设计行与 eink 旧行），多选态换成勾选圈。
  for (final bool eink in <bool>[false, true]) {
    testWidgets('触屏：专辑页曲目行尾「⋯」开菜单，从音乐库移除真落库（eink=$eink）', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1600);
      addTearDown(tester.view.reset);
      await pumpList(tester, await albumPage(), eink: eink);
      final Finder more = find.byKey(
        const ValueKey<String>('music-track-menu-d2'),
      );
      expect(more, findsOneWidget, reason: '专辑曲目行尾要有「⋯」');
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(menuAction('addToQueue'), findsOneWidget);
      expect(menuAction('select'), findsOneWidget);
      final Finder remove = menuAction('removeFromLibrary');
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(liveUids(await db.listMusicTracks(albumUid: 'al')), <String>{
        'd1',
      });

      // 多选态行尾只剩勾选圈，不再有「⋯」。
      await tester.longPress(
        find.byKey(const ValueKey<String>('music-album-track-d1')),
      );
      await tester.pumpAndSettle();
      expect(bar(), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('music-track-menu-d1')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('触屏：专辑页色块长按开菜单，菜单「多选」进入；多选态长按 = 勾选', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    MusicViewStyleStore.instance.resetForTesting();
    addTearDown(MusicViewStyleStore.instance.resetForTesting);
    await MusicViewStyleStore.instance.set(
      MusicViewKind.tracks,
      MusicViewStyle.blocks,
    );
    await pumpList(tester, await albumPage());
    Finder block(String uid) =>
        find.byKey(ValueKey<String>('music-album-track-$uid'));
    expect(tester.widget(block('d1')), isA<MusicTrackBlock>());
    await tester.longPress(block('d1'));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing, reason: '长按先弹菜单，不直接进多选');
    final Finder select = menuAction('select');
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(find.text(t.music_selection_count(n: 1)), findsOneWidget);

    await tester.longPress(block('d2'));
    await tester.pumpAndSettle();
    expect(menuAction('select'), findsNothing);
    expect(find.text(t.music_selection_count(n: 2)), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
