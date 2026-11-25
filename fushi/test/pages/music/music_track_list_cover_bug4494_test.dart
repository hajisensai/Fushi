import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// BUG-4494：「歌曲」分区（及艺人页 / 歌单）的本地曲目行写死音符图标，不画封面；
/// 专辑网格与「继续收听」却用专辑封面。本地行改为与它们同一来源。

MusicTrackRow _track(
  String uid, {
  String? albumUid,
  bool hasEmbeddedCover = false,
}) => MusicTrackRow(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'Title $uid',
  albumUid: albumUid,
  isLossless: true,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: hasEmbeddedCover,
  addedAt: 1,
);

MusicAlbumRow _album(String uid, {String? coverPath, String? coverTrackUid}) =>
    MusicAlbumRow(
      albumUid: uid,
      title: 'Album $uid',
      coverPath: coverPath,
      coverTrackUid: coverTrackUid,
      addedAt: 1,
      updatedAt: 1,
    );

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
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

void main() {
  group('musicLocalTrackCoverOf', () {
    test('专辑目录封面优先，内嵌封面取专辑选定的那首', () {
      final MusicTrackRow a = _track('a', albumUid: 'x');
      final MusicTrackRow b = _track(
        'b',
        albumUid: 'x',
        hasEmbeddedCover: true,
      );
      final Map<String, String> paths = musicLocalTrackPathsOf(
        <MusicLibraryEntry>[MusicLocalEntry(a), MusicLocalEntry(b)],
      );
      final MusicTrackCoverSource cover = musicLocalTrackCoverOf(
        a,
        album: _album('x', coverPath: '/music/folder.jpg', coverTrackUid: 'b'),
        pathByUid: paths,
      );
      expect(cover.coverPath, '/music/folder.jpg');
      // 同一张专辑各行共用 b 的内嵌封面（一次读取），不是 a 自己（a 没有内嵌图）。
      expect(cover.embeddedFromPath, '/music/b.flac');
    });

    test('专辑选定的那首不在本列表：退回这首自己的内嵌封面', () {
      final MusicTrackRow a = _track(
        'a',
        albumUid: 'x',
        hasEmbeddedCover: true,
      );
      final MusicTrackCoverSource cover = musicLocalTrackCoverOf(
        a,
        album: _album('x', coverTrackUid: 'elsewhere'),
        pathByUid: musicLocalTrackPathsOf(<MusicLibraryEntry>[
          MusicLocalEntry(a),
        ]),
      );
      expect(cover.coverPath, isNull);
      expect(cover.embeddedFromPath, '/music/a.flac');
    });

    test('没有专辑、没有内嵌图：两个都为空（画占位）', () {
      final MusicTrackCoverSource cover = musicLocalTrackCoverOf(
        _track('a'),
        album: null,
        pathByUid: const <String, String>{},
      );
      expect(cover.coverPath, isNull);
      expect(cover.embeddedFromPath, isNull);
    });
  });

  group('MusicTrackList 本地行', () {
    late FushiDatabase db;
    late Directory dir;
    late ProviderContainer container;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('fushi_track_list_cover_');
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      final _AppModel app = _AppModel(db: db, prefs: prefs, dir: dir);
      container = ProviderContainer(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      dir.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester, Widget list) async {
      LocaleSettings.setLocale(AppLocale.en);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(useMaterial3: true),
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

    testWidgets('歌曲分区：每行画专辑封面（不是写死的音符图标）', (WidgetTester tester) async {
      final MusicAlbumRow album = _album(
        'x',
        coverPath: '/music/folder.jpg',
        coverTrackUid: 'b',
      );
      await pump(
        tester,
        MusicTrackList(
          tracks: <MusicTrackRow>[
            _track('a', albumUid: 'x'),
            _track('b', albumUid: 'x', hasEmbeddedCover: true),
            _track('loose'),
          ],
          albums: <String, MusicAlbumRow>{'x': album},
          context: MusicQueueContext.mixed,
        ),
      );
      final List<MusicCover> covers = tester
          .widgetList<MusicCover>(find.byType(MusicCover))
          .toList();
      expect(covers, hasLength(3));
      expect(covers[0].coverPath, '/music/folder.jpg');
      expect(covers[0].embeddedFromPath, '/music/b.flac');
      expect(covers[1].embeddedFromPath, '/music/b.flac');
      expect(covers[2].coverPath, isNull);
      expect(covers[2].embeddedFromPath, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('专辑页（显示轨号）仍是轨号，不画封面', (WidgetTester tester) async {
      await pump(
        tester,
        MusicTrackList(
          tracks: <MusicTrackRow>[_track('a', albumUid: 'x')],
          albums: <String, MusicAlbumRow>{'x': _album('x')},
          context: MusicQueueContext.album,
          showTrackNumbers: true,
        ),
      );
      expect(find.byType(MusicCover), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
