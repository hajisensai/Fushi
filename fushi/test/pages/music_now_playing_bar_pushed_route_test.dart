import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

Future<FushiDatabase> _seed() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  await db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        MusicTracksCompanion.insert(
          trackUid: 't1',
          path: '/m/t1.flac',
          title: 'Song t1',
          albumUid: const Value<String?>('al'),
          artistCredit: const Value<String?>('Singer'),
          codec: const Value<String?>('flac'),
          isLossless: const Value<bool>(true),
          durationMs: const Value<int?>(185000),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
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

  testWidgets('pushed album page mounts the music mini bar', (
    WidgetTester tester,
  ) async {
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
    expect(find.byType(MusicNowPlayingBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
