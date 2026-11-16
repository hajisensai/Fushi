import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/book_detail_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/shell_layout.dart';
import '../helpers/test_platform_services.dart';

/// 书架点书卡（2026-11-16 所有者「有元数据的都要有详情页，小说也是」）：刮削过的
/// 单本书先进元数据详情页（主按钮再开书），没刮削的书照旧直接开书；书卡菜单
/// 「详情」对所有书都在。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<String> opened = <String>[];

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    opened.add(item?.mediaIdentifier ?? '');
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_scraped_tap_pp',
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
  late _RecordingAppModel appModel;
  late Directory storeDir;
  late List<MediaItem> epubItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_shelf_scraped_tap');
    appModel = _RecordingAppModel()
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    epubItems = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedEpub(String bookKey, String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey.epub',
        extractDir: pathProviderDir.path,
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 0,
      ),
    );
    epubItems.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      ),
    );
  }

  /// 「Scraped」有单本刮削资料，「Plain」没有。
  Future<void> seedLibrary() async {
    await seedEpub('scrapedKey', 'Scraped');
    await seedEpub('plainKey', 'Plain');
    await db.upsertItemScrapeMeta(
      ItemScrapeMetaCompanion.insert(
        mediaType: MediaKind.epub.dbValue,
        entryKey: (await db.resolveEpubBookUid('scrapedKey'))!,
        source: 'bangumi',
        title: const Value<String>('魔女之旅'),
        summary: const Value<String>('旅人伊蕾娜周游诸国的故事。'),
        rating: const Value<double>(7.8),
        scrapedAt: 1,
      ),
    );
    await prefs.setShelfSortModeName('title');
  }

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(epubItems),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
      selectedTagIdsProvider.overrideWith((ref) => const <int>{}),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: gridShellTheme(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Finder epubCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  testWidgets('刮削过的书点卡进详情页，主按钮再开书', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);

    await tester.tap(epubCard('scrapedKey'));
    await tester.pumpAndSettle();

    expect(find.byType(BookDetailPage), findsOneWidget);
    expect(appModel.opened, isEmpty, reason: '点刮削过的书不直接开阅读器');

    await tester.tap(find.byKey(const ValueKey<String>('book-detail-open')));
    await tester.pumpAndSettle();
    expect(appModel.opened, <String>[
      ReaderFushiSource.mediaIdentifierFor('scrapedKey'),
    ]);
  });

  testWidgets('没刮削的书点卡照旧直接开书', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);

    await tester.tap(epubCard('plainKey'));
    await tester.pumpAndSettle();

    expect(find.byType(BookDetailPage), findsNothing);
    expect(appModel.opened, <String>[
      ReaderFushiSource.mediaIdentifierFor('plainKey'),
    ]);
  });

  testWidgets('书卡菜单「详情」对没刮削的书也在', (WidgetTester tester) async {
    await seedLibrary();
    await pumpPage(tester);

    final TestGesture right = await tester.startGesture(
      tester.getCenter(epubCard('plainKey')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await right.up();
    await tester.pumpAndSettle();

    final Finder detail = find.text(t.book_detail_open_action);
    expect(detail, findsOneWidget);
    await tester.tap(detail);
    await tester.pumpAndSettle();
    expect(find.byType(BookDetailPage), findsOneWidget);
    expect(appModel.opened, isEmpty);
  });
}
