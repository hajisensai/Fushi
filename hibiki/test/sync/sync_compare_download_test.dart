import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// 一个最小但 [EpubImporter] 能真正解析的 EPUB：mimetype + container.xml +
/// content.opf + 一个 xhtml 章节。返回 zip 字节（与 test/epub 里的构造同款）。
Uint8List _buildMinimalEpub(String title) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  add('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>Hello.</p></body>
</html>
''');

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 对比对话框的 fake backend：远端有一本本机没有的书（含 `.epub`）。
/// [getAsset] 把一个真实可解析的最小 EPUB 写到目标文件，从而让 Apply 走完
/// `importRemoteBookFolder` → `EpubImporter.importFromPath` 的真实导入路径。
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.bookTitle, required this.folderId});

  final String bookTitle;
  final String folderId;

  static const String epubAssetId = 'epubAsset1';

  static const String _dictNs = '__dictionaries__';

  /// 记录 [getAsset] 被请求过的资产 id（断言确有下载发生）。
  final List<String> fetchedAssetIds = <String>[];

  // ── _load 走到的读方法 ───────────────────────────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      <DriveFile>[DriveFile(id: folderId, name: bookTitle)];
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String f) async =>
      const DriveSyncFiles();
  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    if (id == _dictNs) return const <AssetEntry>[];
    if (id == folderId) {
      return const <AssetEntry>[
        AssetEntry(id: epubAssetId, name: 'book.epub'),
      ];
    }
    return const <AssetEntry>[];
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => null;
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  Future<bool> get isAuthenticated async => true;

  // ── 下载：写一个真实可解析的 EPUB 到目标 ─────────────────────────
  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) async {
    fetchedAssetIds.add(assetId);
    await destination.writeAsBytes(_buildMinimalEpub(bookTitle));
  }

  // ── 不应触达的成员 ────────────────────────────────────────────────
  @override
  Future<String?> get currentEmail async => throw UnimplementedError();
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async =>
      throw UnimplementedError();
  @override
  Future<void> refreshAuth() async => throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  void clearCache() => throw UnimplementedError();
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // EpubStorage 经 path_provider 平台通道取应用文档目录；单测无插件实现，
  // mock 成一个临时目录即可，导入的书才真正落盘 + 入库。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_compare_download_pp');
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
    // best-effort：Windows 上刚导入的书目录可能仍被句柄占用，清理失败不应判错。
    try {
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'remote-only book renders a checked download control and Apply '
      'imports it', (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_compare_download_tmp');
    addTearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeSyncBackend fake =
        _FakeSyncBackend(bookTitle: 'RemoteOnlyBook', folderId: 'folderX');

    // 前置：本机没有任何书。
    expect(await db.getAllEpubBooks(), isEmpty);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: fake, tempDir: tempDir),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // remote-only 条目渲染出「下载」控件，且默认勾选（useRemote）。
    expect(find.text('RemoteOnlyBook'), findsOneWidget);
    expect(find.text(t.sync_compare_download), findsOneWidget);
    final Checkbox checkbox =
        tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(checkbox.value, isTrue, reason: 'remote-only 默认勾选下载');

    // Apply 按钮计数为 1（remote-only 计入 actionable）。
    expect(find.text(t.sync_compare_apply(count: 1)), findsOneWidget);

    // 点 Apply（widget 测试可用 tap）→ 真走 importRemoteBookFolder。
    // 导入经真实后台 isolate（EpubImporter.compute）+ 真实文件 IO；这些真实
    // 异步只在 runAsync 提供的真实事件循环里推进，fake 时钟的 pump 推不动它，
    // 所以整个「触发 + 等落库」必须在 runAsync 内完成。
    List<EpubBookRow> books = const <EpubBookRow>[];
    await tester.runAsync(() async {
      await tester.tap(find.text(t.sync_compare_apply(count: 1)));
      for (int i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        books = await db.getAllEpubBooks();
        if (books.isNotEmpty) break;
      }
    });
    await tester.pump();

    // 下载确实发生，且远端书被导入本机。
    expect(fake.fetchedAssetIds, contains(_FakeSyncBackend.epubAssetId));
    expect(books, isNotEmpty, reason: '点 Apply 必须把远端独有书真正下载导入本机');
    expect(books.any((EpubBookRow b) => b.title == 'RemoteOnlyBook'), isTrue);
  });
}
