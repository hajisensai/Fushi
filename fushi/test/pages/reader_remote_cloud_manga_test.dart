import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

// 反馈 ecNgkRQcTk：云盘同步里未下载的漫画（`<title>.manga.zip`）以「远端 · 未下载」
// 占位卡出现在**书籍**书架而不是漫画书架。本文件走真实 [CloudRemoteBookClient]
// （假 SyncBackend 只替换网络）+ 真实书架页 + 真实导入器，钉住：
// - 云盘漫画占位卡只出现在漫画书架（清单按 `.manga.zip` 推断 format=manga）；
// - 从漫画书架占位卡下载会把漫画包导入成 format=manga 的本地行，任务正常收尾、
//   占位卡让位（BUG-4223）。

const String _folderId = 'fid_takagi_05';
const String _title = 'Takagi 05';
const String _cardKey = 'remote_book_card_Takagi_05';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_cloud_manga_pp',
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
  late AppModel appModel;
  late _CloudMangaBackend backend;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_cloud_manga_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    backend = _CloudMangaBackend();
  });

  tearDown(() async {
    homeShellTabNotifier.value = HomeTab.books;
    await db.close();
  });

  Widget buildApp({required bool mangaOnly}) => ProviderScope(
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
            mangaOnly: mangaOnly,
            remoteBookClientLoader: () async => CloudRemoteBookClient(
              backend: backend,
              backendType: SyncBackendType.oneDrive,
              rootFolderId: 'root',
              database: db,
            ),
            remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                File('${pathProviderDir.path}/${book.title.hashCode}.epub'),
          ),
        ),
      ),
    ),
  );

  testWidgets('云盘 .manga.zip 远端占位卡不进书籍书架', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(mangaOnly: false));
    await tester.pumpAndSettle();
    expect(backend.listedRoot, isTrue, reason: '前置：书籍书架确实拉了云盘清单');
    expect(
      find.byKey(const ValueKey<String>(_cardKey)),
      findsNothing,
      reason: '书籍书架不能收云盘漫画包（反馈 ecNgkRQcTk）',
    );
  });

  testWidgets('云盘 .manga.zip 远端占位卡出现在漫画书架', (WidgetTester tester) async {
    homeShellTabNotifier.value = HomeTab.manga;
    await tester.pumpWidget(buildApp(mangaOnly: true));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>(_cardKey)),
      findsOneWidget,
      reason: '漫画书架要渲染云盘漫画占位卡',
    );
  });

  testWidgets('从漫画书架下载云盘漫画包：导入成漫画、任务收尾、占位卡让位', (WidgetTester tester) async {
    final Directory booksRoot = Directory.systemTemp.createTempSync(
      'fushi_cloud_manga_books',
    );
    EpubStorage.debugBaseDirectoryOverride = booksRoot.path;
    addTearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      booksRoot.deleteSync(recursive: true);
    });
    homeShellTabNotifier.value = HomeTab.manga;
    await tester.pumpWidget(buildApp(mangaOnly: true));
    await tester.pumpAndSettle();
    final Finder card = find.byKey(const ValueKey<String>(_cardKey));
    expect(card, findsOneWidget, reason: '前置：漫画书架有云盘漫画占位卡');
    final InterconnectDownloadManager manager = ProviderScope.containerOf(
      tester.element(find.byType(ReaderFushiHistoryPage)),
    ).read(interconnectDownloadManagerProvider);
    final String taskId = InterconnectDownloadManager.bookTaskId(_folderId);

    InterconnectDownloadTask? finished;
    await tester.runAsync(() async {
      await tester.tap(card);
      final Stopwatch watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 15)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final InterconnectDownloadTask? task = manager.tasks[taskId];
        if (task != null && !task.isRunning) {
          finished = task;
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    // 落地后的远端清单重载（去重）是真实 DB IO：先让 FakeAsync 把它排上，再给真时钟跑完。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    expect(finished?.status, InterconnectDownloadStatus.completed);
    expect(backend.getAssetCalls, <String>['manga_asset']);
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.format, BookFormat.manga.dbValue);
    expect(rows.single.bookKey, _title);
    expect(card, findsNothing, reason: '入库后占位卡必须让位给本地卡');
  });
}

/// 只替换网络的云盘后端：根下一本书文件夹，内含新版漫画包 `<title>.manga.zip`。
class _CloudMangaBackend implements SyncBackend {
  final List<String> getAssetCalls = <String>[];
  bool listedRoot = false;

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    listedRoot = true;
    return <SyncFileRef>[SyncFileRef(id: _folderId, name: _title)];
  }

  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      namespaceId == _folderId
      ? const <AssetEntry>[
          AssetEntry(id: 'manga_asset', name: '$_title.manga.zip'),
        ]
      : const <AssetEntry>[];

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    getAssetCalls.add(assetId);
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(_mangaPackageBytes());
    onProgress?.call(1.0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected backend call: ${invocation.memberName}',
  );
}

final List<int> _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==',
);

/// 漫画包：zip 根含 `manga.json` + 页图（= 书目录整树包）。
List<int> _mangaPackageBytes() {
  final Archive archive = Archive();
  final List<int> json = utf8.encode(
    jsonEncode(<String, Object?>{
      'pages': <Object?>[
        <String, Object?>{
          'url': 'page.png',
          'width': 1,
          'height': 1,
          'blocks': <Object?>[],
        },
      ],
    }),
  );
  archive.addFile(ArchiveFile('manga.json', json.length, json));
  archive.addFile(ArchiveFile('page.png', _tinyPngBytes.length, _tinyPngBytes));
  return ZipEncoder().encode(archive)!;
}
