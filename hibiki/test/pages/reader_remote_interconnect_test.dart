import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_pp');
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

  late HibikiDatabase db;
  late AppModel appModel;
  late _FakeRemoteBookClient remoteClient;
  late List<File> importedFiles;
  late File remoteBookCover;
  // 注入的本地 EPUB bookKey（importer 返回它，音频导入据此作 bookKeyOverride）。
  late String? importedBookKey;
  // 有声书接线观测：fetcher 收到的远端 bookKey + importer 收到的 (file, override)。
  late List<String> fetchedAudiobookKeys;
  late List<({File package, String? bookKeyOverride})> importedAudiobooks;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_store');
    remoteBookCover = File('${storeDir.path}/remote-book-cover.png')
      ..writeAsBytesSync(_tinyPngBytes);
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    remoteClient = _FakeRemoteBookClient(coverPath: remoteBookCover.path);
    importedFiles = <File>[];
    importedBookKey = 'local-book-key';
    fetchedAudiobookKeys = <String>[];
    importedAudiobooks = <({File package, String? bookKeyOverride})>[];
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(
              const <MediaItem>[],
            ),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) => Spacing(
              dataBuilder: (_) => SpacingData.generate(10),
              child: child ?? const SizedBox.shrink(),
            ),
            home: Scaffold(
              body: ReaderHibikiHistoryPage(
                remoteBookClientLoader: () async => remoteClient,
                remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                    File(
                  '${pathProviderDir.path}/${book.title.hashCode}.epub',
                ),
                remoteBookImporter: (File file) async {
                  importedFiles.add(file);
                  return importedBookKey;
                },
                remoteAudiobookFetcher: (String remoteBookKey) async {
                  fetchedAudiobookKeys.add(remoteBookKey);
                  final File pkg = File(
                    '${pathProviderDir.path}/$remoteBookKey.hibikiaudio',
                  );
                  await pkg.writeAsBytes(<int>[9, 9, 9]);
                  return pkg;
                },
                remoteAudiobookImporter:
                    (File package, String? bookKeyOverride) async {
                  importedAudiobooks.add(
                    (package: package, bookKeyOverride: bookKeyOverride),
                  );
                },
              ),
            ),
          ),
        ),
      );

  testWidgets('bookshelf exposes Hibiki interconnect remote books',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(t.remote_book_interconnect), findsOneWidget);
    expect(find.text(t.remote_book_paired_device), findsOneWidget);
    expect(find.text('Remote Book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )),
      findsOneWidget,
    );

    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    expect(source, isNot(contains('浏览电脑')));
    expect(source.toLowerCase(), isNot(contains('computer')));
  });

  testWidgets('remote book uses the shelf card cover layout',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('remote_book_cover_Remote_Book'),
        ),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.byType(AspectRatio)),
        findsOneWidget);
  });

  testWidgets('remote book title renders below the cover',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Rect coverRect = tester.getRect(find.byKey(
      const ValueKey<String>('remote_book_cover_Remote_Book'),
    ));
    final Rect titleRect = tester.getRect(find.text('Remote Book'));

    // Remote shelf cards share the same stable cover + footer layout as local
    // books: cover art stays unobscured and the title lives below it.
    expect(
      titleRect.top,
      greaterThanOrEqualTo(coverRect.bottom - 0.5),
      reason: 'remote book title must render in the footer below the cover',
    );
    expect(
      titleRect.bottom,
      greaterThan(coverRect.bottom),
      reason: 'the title footer must not be drawn over the cover artwork',
    );
  });

  testWidgets(
      'remote book renders normal-book type badge by default '
      '(TODO-655a)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    final Finder badge = find.descendant(
      of: card,
      matching: find.byKey(
        const ValueKey<String>('remote_book_type_badge_Remote_Book'),
      ),
    );
    expect(badge, findsOneWidget,
        reason: 'remote book card must show a type badge like local books');
    // Normal book → book icon, never the headphones (audiobook) icon.
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.headphones_outlined)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.menu_book_outlined)),
      findsOneWidget,
    );
  });

  testWidgets('remote audiobook renders headphones type badge (TODO-655a)',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      hasAudiobook: true,
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder badge = find.byKey(
      const ValueKey<String>('remote_book_type_badge_Remote_Book'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.headphones_outlined)),
      findsOneWidget,
      reason: 'a remote book with an audiobook must show the headphones badge',
    );
  });

  testWidgets(
      'remote book grid spans full shelf width like local books '
      '(TODO-655b)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // The remote grid shares the local sliver-grid full-width baseline: its
    // GridView must span the same width as the enclosing scroll viewport, so
    // cell width matches local book cards (no shrinking from section padding).
    final Finder grid = find.descendant(
      of: find.byType(ReaderHibikiHistoryPage),
      matching: find.byType(GridView),
    );
    expect(grid, findsOneWidget);
    final Finder viewport = find
        .ancestor(
          of: find.byType(CustomScrollView),
          matching: find.byType(LayoutBuilder),
        )
        .first;
    final double gridWidth = tester.getSize(grid).width;
    final double shelfWidth = tester.getSize(viewport).width;
    expect(
      gridWidth,
      closeTo(shelfWidth, 0.5),
      reason: 'remote grid must span the full shelf width (no section padding '
          'shrinking the cards below the local baseline)',
    );
  });

  testWidgets('remote book download action pulls epub and imports locally',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (remoteClient.downloadedTitles.isNotEmpty &&
            importedFiles.isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    expect(remoteClient.downloadedTitles, <String>['Remote Book']);
    expect(importedFiles.single.existsSync(), isTrue);
  });

  testWidgets('remote book download uses stable bookKey for special titles',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      title: r'Vol 1/2\3?..: Finale',
      bookKey: 'Vol_1_2_3_Finale',
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (remoteClient.downloadedTitles.isNotEmpty &&
            importedFiles.isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    expect(remoteClient.downloadedTitles, <String>['Vol_1_2_3_Finale']);
    expect(importedFiles.single.existsSync(), isTrue);
  });

  testWidgets(
      'remote audiobook download wires getRemoteAudiobook + import with '
      'stable remote key and local bookKey override (BUG-406)',
      (WidgetTester tester) async {
    // host 把书名重复时加了后缀，真实 bookKey 与 sanitizeTtuFilename(title) 不同。
    // 下载有声书必须用 host 传来的真实 bookKey（= downloadId），否则 404（BUG-414）。
    const String hostAudiobookKey = 'Vol_1_2_Audio_2';
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      title: r'Vol 1/2: Audio',
      bookKey: hostAudiobookKey,
      hasAudiobook: true,
    );
    importedBookKey = 'local-renamed-key';
    // 守护：真实 key 与 sanitize(title) 必须不同，回归用例才有意义。
    expect(hostAudiobookKey,
        isNot(equals(sanitizeTtuFilename(r'Vol 1/2: Audio'))));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (importedAudiobooks.isNotEmpty) break;
      }
    });
    await tester.pump();

    // EPUB still imported.
    expect(importedFiles.single.existsSync(), isTrue);
    // Audiobook fetched with the host's real bookKey (= downloadId = bookKey ?? title),
    // NOT sanitizeTtuFilename(title). Reverting the fix flips this back to sanitize(title)
    // and turns this red (BUG-414 regression guard).
    expect(fetchedAudiobookKeys, <String>[hostAudiobookKey]);
    expect(fetchedAudiobookKeys,
        isNot(equals(<String>[sanitizeTtuFilename(r'Vol 1/2: Audio')])));
    // Audiobook imported once, bound to the *local* imported EPUB bookKey.
    expect(importedAudiobooks, hasLength(1));
    expect(importedAudiobooks.single.bookKeyOverride, 'local-renamed-key');
    expect(importedAudiobooks.single.package.existsSync(), isTrue);
  });

  testWidgets(
      'remote book without audiobook never touches the audiobook wiring '
      '(BUG-406)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (importedFiles.isNotEmpty) break;
      }
    });
    await tester.pump();

    expect(importedFiles.single.existsSync(), isTrue);
    expect(fetchedAudiobookKeys, isEmpty);
    expect(importedAudiobooks, isEmpty);
  });
}

class _FakeRemoteBookClient implements RemoteBookClient {
  _FakeRemoteBookClient({
    required this.coverPath,
    this.title = 'Remote Book',
    this.bookKey,
    this.hasAudiobook = false,
  });

  final String coverPath;
  final String title;
  final String? bookKey;
  final bool hasAudiobook;
  final List<String> downloadedTitles = <String>[];

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
        RemoteBookInfo.fromJson(<String, Object?>{
          'title': title,
          if (bookKey != null) 'bookKey': bookKey,
          'hasContent': true,
          'coverPath': coverPath,
          if (hasAudiobook) 'hasAudiobook': true,
        }),
      ];

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    downloadedTitles.add(title);
    await destination.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
