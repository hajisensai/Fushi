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
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
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

  testWidgets('bookshelf mixes interconnect remote books into the main grid',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 多端库联合视图（spec §2.1，撤独立远端分区）：远端书以占位卡混排进主网格——
    // 卡片在、带云角标 ☁、右上角保留下载按钮（能力未丢失）。
    expect(find.text('Remote Book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_cloud_badge_Remote_Book',
      )),
      findsOneWidget,
    );
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

  testWidgets(
      'cloud backend remote books also mix into the main grid as placeholders',
      (WidgetTester tester) async {
    // 撤独立远端分区后不再有「互联 vs 云端」分区文案区分——云盘后端
    // （CloudRemoteBookClient，来源 cloud）的远端书同样以占位卡混排进主网格，
    // 与互联来源共用同一占位卡渲染（云角标 + 远端封面 + 下载按钮）。
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      sourceKind: RemoteBookSourceKind.cloud,
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Remote Book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_cloud_badge_Remote_Book',
      )),
      findsOneWidget,
    );
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
      'remote book renders as a placeholder card in the main scatter grid '
      '(spec §2.1 mixed grid)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    // 撤独立远端 GridView 分区后，远端占位卡是主散卡网格（SliverGrid）的一个 cell，
    // 与本地书卡同一网格、同一卡宽基准（不再被独立 section 的内边距压窄）。
    expect(
      find.ancestor(of: card, matching: find.byType(SliverGrid)),
      findsOneWidget,
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

  testWidgets('BUG-813: 下载远端书把 host 阅读进度回填进本地 reader_positions',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      progress: const RemoteBookProgress(
        sectionIndex: 3,
        normCharOffset: 4200,
        charOffset: 137,
        updatedAtMs: 1700000000000,
      ),
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )));
      // 轮询直到进度回填落库（下载 → 导入 → 拉进度 upsert 是异步链）。
      for (int i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (await db.getReaderPosition('local-book-key') != null) break;
      }
    });
    await tester.pump();

    // 下载动作把 host 端阅读进度回填进本地 reader_positions（键 = 导入后的本地
    // bookKey，非 host downloadId）——手动下载不再丢「阅读记录」。
    final ReaderPositionRow? row = await db.getReaderPosition('local-book-key');
    expect(row, isNotNull,
        reason: 'BUG-813：下载远端书必须把 host 阅读进度落进 reader_positions');
    expect(row!.sectionIndex, 3);
    expect(row.normCharOffset, 4200);
    expect(row.charOffset, 137);
    expect(row.updatedAt, 1700000000000);
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
    this.sourceKind = RemoteBookSourceKind.interconnect,
    this.progress = RemoteBookProgress.empty,
  });

  final String coverPath;
  final String title;
  final String? bookKey;
  final bool hasAudiobook;
  final RemoteBookSourceKind sourceKind;
  // BUG-813：host 端该书的阅读进度，供「下载回填进度」用例配置。
  final RemoteBookProgress progress;
  final List<String> downloadedTitles = <String>[];

  @override
  RemoteBookSourceKind get remoteSourceKind => sourceKind;

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
      progress;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
