import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4388: two manga volumes imported one after the other while the shelf
/// is open (mokuro catalog downloads, import dialog, drag and drop) became
/// one series card only after something else reloaded the shelf maps. The
/// shelf now regroups when the set of books changes.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_group_import_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_group_import_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  /// The row a mokuro catalog volume lands as (`format = 'manga'`, no source
  /// metadata, no chapters).
  Future<void> importVolume(String title) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/manga/$title',
      extractDir: '/manga/$title',
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      format: const Value<String>('manga'),
    ),
  );

  testWidgets('volumes imported while the shelf is open join one series', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(await db.getAllMediaCollections(), isEmpty);

    await importVolume('Ajin (HD Scan) Ajin 01');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      await db.getAllMediaCollections(),
      isEmpty,
      reason: 'one volume is not a series yet',
    );

    await importVolume('Ajin (HD Scan) Ajin 02');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections, hasLength(1));
    expect(collections.single.name, 'Ajin (HD Scan) Ajin');
    expect(await db.getCollectionItems(collections.single.id), hasLength(2));
  });
}
