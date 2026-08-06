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
import 'package:hibiki/src/sync/remote_library_source.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5）书架占位卡混排 widget 守卫：
///  ① 远端书以占位卡混排进主网格（不再独立分区），带云角标 ☁；
///  ② 本地已有同 bookKey 的书不重复（只显示本地卡，远端占位去重隐藏）；
///  ③ 「显示远端条目」开关关闭 → 占位卡全部不渲染；
///  ④ 远端目录拉取失败 → 占位卡不出现（离线=只剩本地；此处本地空 → 空态占位）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_mixed_grid_book_pp');
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
  late PreferencesRepository prefs;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_mixed_grid_book_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp(RemoteBookClient client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(const <MediaItem>[]),
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
                remoteBookClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  testWidgets('远端书混排进主 SliverGrid 且带云角标', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(title: 'Remote Book', hasContent: true),
      ],
    )));
    await tester.pumpAndSettle();

    final Finder card = find
        .byKey(ValueKey<String>('remote_book_card_${safeKey('Remote Book')}'));
    expect(card, findsOneWidget);
    expect(
      find.byKey(ValueKey<String>(
          'remote_book_cloud_badge_${safeKey('Remote Book')}')),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: card, matching: find.byType(SliverGrid)),
      findsOneWidget,
      reason: '远端占位卡必须是主散卡网格（SliverGrid）的一个 cell（混排，非独立分区）',
    );
  });

  testWidgets('本地已有同 bookKey 的书不重复渲染远端占位', (WidgetTester tester) async {
    final String key = sanitizeTtuFilename('Dup Book');
    final Directory extractDir =
        Directory('${pathProviderDir.path}/dup_extract')..createSync();
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: key,
      title: 'Dup Book',
      epubPath: '${extractDir.path}/x.epub',
      extractDir: extractDir.path,
      chapterCount: 1,
      chaptersJson: '["a"]',
      importedAt: 0,
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(title: 'Dup Book', hasContent: true),
        RemoteBookInfo(title: 'Only Remote Book', hasContent: true),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('remote_book_card_${safeKey('Dup Book')}')),
      findsNothing,
      reason: '本地已有同 bookKey → 远端占位去重隐藏',
    );
    expect(
      find.byKey(
          ValueKey<String>('remote_book_card_${safeKey('Only Remote Book')}')),
      findsOneWidget,
    );
  });

  testWidgets('「显示远端条目」开关关闭 → 占位卡全部不渲染', (WidgetTester tester) async {
    await prefs.setShowRemoteEntries(false);
    await tester.pumpWidget(buildApp(_ListFakeRemoteBookClient(
      const <RemoteBookInfo>[
        RemoteBookInfo(title: 'Remote Book', hasContent: true),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
          ValueKey<String>('remote_book_card_${safeKey('Remote Book')}')),
      findsNothing,
      reason: '开关关闭时远端占位卡不得渲染',
    );
  });

  testWidgets('远端目录拉取失败 → 占位卡不出现（只剩本地）', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(_ThrowingRemoteBookClient()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
          ValueKey<String>('remote_book_card_${safeKey('Remote Book')}')),
      findsNothing,
      reason: '远端目录拉取失败时占位卡不出现',
    );
    // 本地空 + 远端失败 → 只剩本地库（此处为空态占位提示，非崩溃）。
    expect(find.text(t.reader_no_books_added), findsOneWidget);
  });
}

class _ListFakeRemoteBookClient implements RemoteBookClient {
  _ListFakeRemoteBookClient(this._books);
  final List<RemoteBookInfo> _books;

  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => _books;

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await destination.writeAsBytes(<int>[1]);
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

/// listRemoteBooks 抛异常 → 页面走 failed 门控（占位卡不出现）。
class _ThrowingRemoteBookClient implements RemoteBookClient {
  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async =>
      throw const SocketException('offline');

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}
