import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';

import '../helpers/test_platform_services.dart';

MusicTracksCompanion _track(
  String uid,
  String album, {
  int? disc,
  int? no,
  int sampleRate = 96000,
  int bitDepth = 24,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Song $uid',
  albumUid: Value<String?>(album),
  artistCredit: const Value<String?>('Singer'),
  codec: const Value<String?>('flac'),
  isLossless: const Value<bool>(true),
  sampleRate: Value<int?>(sampleRate),
  bitDepth: Value<int?>(bitDepth),
  discNo: Value<int?>(disc),
  trackNo: Value<int?>(no),
  durationMs: const Value<int?>(185000),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

Future<FushiDatabase> _seed() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  await db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        _track('t1', 'al', disc: 1, no: 1),
        _track('t2', 'al', disc: 2, no: 1),
      ],
      albums: <MusicAlbumsCompanion>[
        MusicAlbumsCompanion.insert(
          albumUid: 'al',
          title: 'Night Album',
          albumArtistCredit: const Value<String?>('Singer'),
          addedAt: 1,
          updatedAt: 1,
        ),
      ],
      artists: <MusicArtistsCompanion>[
        MusicArtistsCompanion.insert(
          artistUid: 'ar',
          name: 'Singer',
          addedAt: 1,
        ),
      ],
      credits: <MusicTrackCreditsCompanion>[
        MusicTrackCreditsCompanion.insert(
          trackUid: 't1',
          artistUid: 'ar',
          role: 'artist',
          creditName: 'Singer',
        ),
      ],
    ),
  );
  return db;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('五个分区；专辑网格 → 歌曲 → 作品空态', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await _pump(tester, app, const MusicLibraryPage());

    for (final MusicLibrarySection s in MusicLibrarySection.values) {
      expect(find.text(musicLibrarySectionLabel(s)), findsWidgets);
    }
    expect(find.text('Night Album'), findsOneWidget);
    expect(find.textContaining('FLAC 24/96'), findsOneWidget);

    await tester.tap(find.text(t.music_section_songs));
    await tester.pumpAndSettle();
    expect(find.text('Song t1'), findsOneWidget);
    expect(find.text('Song t2'), findsOneWidget);
    expect(find.text('3:05'), findsNWidgets(2));

    await tester.tap(find.text(t.music_section_works));
    await tester.pumpAndSettle();
    expect(find.text(t.music_works_empty), findsOneWidget);

    await tester.tap(find.text(t.music_section_artists));
    await tester.pumpAndSettle();
    expect(find.text('Singer'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('搜索框按当前分区筛选；无匹配给空态；清空恢复', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await _pump(tester, app, const MusicLibraryPage());
    final Finder field = find.byKey(const ValueKey<String>('music-library-search'));
    expect(field, findsOneWidget);

    await tester.tap(find.text(t.music_section_songs));
    await tester.pumpAndSettle();
    await tester.enterText(field, 'song t1');
    await tester.pumpAndSettle();
    expect(find.text('Song t1'), findsOneWidget);
    expect(find.text('Song t2'), findsNothing);

    await tester.enterText(field, 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text(t.music_library_search_empty), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(find.text('Song t1'), findsOneWidget);
    expect(find.text('Song t2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('搜索框与分段选择器左缘对齐、宽 520-600、每个分区都在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await _pump(tester, app, const MusicLibraryPage());
    final Finder field = find.byKey(
      const ValueKey<String>('music-library-search'),
    );
    final Finder selector = find.byType(FushiPillSegmentedButton<MusicLibrarySection>);
    final double selectorLeft = tester.getTopLeft(selector).dx;
    final Finder bar = find.ancestor(
      of: field,
      matching: find.byType(ConstrainedBox),
    );
    for (final MusicLibrarySection s in MusicLibrarySection.values) {
      await tester.tap(find.text(musicLibrarySectionLabel(s)).first);
      await tester.pumpAndSettle();
      expect(field, findsOneWidget, reason: '$s');
      final Rect r = tester.getRect(field);
      expect(r.left, selectorLeft, reason: '$s left edge');
      expect(r.width, inInclusiveRange(520, 600), reason: '$s width');
      expect(tester.getTopLeft(selector).dy, lessThan(r.top));
    }
    expect(bar, findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('空曲库显示添加文件夹入口', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await _pump(tester, app, const MusicLibraryPage());
    expect(find.text(t.music_library_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_empty_add_folder')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('专辑页：碟片分组 + 格式徽章 + Hi-Res', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow album = snap.albums.single;
    await _pump(
      tester,
      app,
      MusicAlbumPage(album: album, tracks: snap.tracksOfAlbum(album.albumUid)),
    );
    expect(find.text(t.music_disc_label(n: 1)), findsOneWidget);
    expect(find.text(t.music_disc_label(n: 2)), findsOneWidget);
    expect(find.text('FLAC 24/96'), findsOneWidget);
    expect(find.text(t.music_hi_res_badge), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('迷你条互斥判据', () {
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: true,
        owner: MediaSessionOwner.audiobook,
      ),
      isFalse,
    );
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: true,
        owner: MediaSessionOwner.music,
      ),
      isTrue,
    );
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: false,
        owner: MediaSessionOwner.none,
      ),
      isTrue,
    );
    expect(
      musicBarVisible(
        musicActive: false,
        audiobookActive: false,
        owner: MediaSessionOwner.music,
      ),
      isFalse,
    );
  });
}
