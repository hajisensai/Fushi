import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/cloud_remote_book_client.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart'
    show kSyncDictionaryNamespace, kSyncLocalAudioNamespace;
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

/// 可控的 fake：根文件夹下若干书文件夹（[folders]，含名字），每个文件夹的子项由
/// [childrenByFolder] 决定（默认含一个 `<name>.epub`）。记录 `listChildren`/`getAsset`
/// 调用与并发峰值，用于断言字段映射 / 保留区过滤 / 内容探测 / 并发上限 / fail-open /
/// 仅下载不二次导入。
class _ControllableSyncBackend implements SyncBackend {
  _ControllableSyncBackend({
    required this.folders,
    required this.childrenByFolder,
    this.throwOnListChildrenFor = const <String>{},
    this.listChildrenDelay = Duration.zero,
  });

  /// 根 listBooks 返回的文件夹（id+name）。
  final List<DriveFile> folders;

  /// folderId → 子项。缺省视为空文件夹。
  final Map<String, List<AssetEntry>> childrenByFolder;

  /// 对这些 folderId 的 listChildren 抛异常（测 fail-open）。
  final Set<String> throwOnListChildrenFor;

  /// 每次 listChildren 的人为延迟（让并发可观测）。
  final Duration listChildrenDelay;

  final List<String> listChildrenCalls = <String>[];
  final List<String> getAssetCalls = <String>[];
  final List<DriveFile> cachedFolders = <DriveFile>[];

  int _inFlightListChildren = 0;
  int maxConcurrentListChildren = 0;

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => folders;

  @override
  void cacheBookFolderIds(List<DriveFile> folders) {
    cachedFolders
      ..clear()
      ..addAll(folders);
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    listChildrenCalls.add(namespaceId);
    _inFlightListChildren += 1;
    if (_inFlightListChildren > maxConcurrentListChildren) {
      maxConcurrentListChildren = _inFlightListChildren;
    }
    try {
      if (listChildrenDelay > Duration.zero) {
        await Future<void>.delayed(listChildrenDelay);
      }
      if (throwOnListChildrenFor.contains(namespaceId)) {
        throw SyncBackendError('boom: $namespaceId');
      }
      return childrenByFolder[namespaceId] ?? const <AssetEntry>[];
    } finally {
      _inFlightListChildren -= 1;
    }
  }

  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) async {
    getAssetCalls.add(assetId);
    await destination.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1.0);
  }

  // ── unused members ─────────────────────────────────────────────────
  @override
  Future<bool> get isAuthenticated async => throw UnimplementedError();
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
  Future<String> findOrCreateRootFolder() async => throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
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
  Future<String> ensureNamespace(String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
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
  @override
  void restoreCache(
          {String? rootFolderId, Map<String, String>? titleToFolderId}) =>
      throw UnimplementedError();
  @override
  String? get cachedRootFolderId => throw UnimplementedError();
  @override
  Map<String, String> get cachedFolderIds => throw UnimplementedError();
  @override
  void evictFolderId(String folderId) => throw UnimplementedError();
}

AssetEntry _epub(String id, String name) => AssetEntry(id: id, name: name);

void main() {
  group('CloudRemoteBookClient.listRemoteBooks', () {
    test(
        'maps folders → RemoteBookInfo with bookKey=folderId, hasContent probe',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <DriveFile>[
          DriveFile(id: 'fid_a', name: 'Book A'),
          DriveFile(id: 'fid_b', name: 'Book B'),
        ],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_a': <AssetEntry>[_epub('asset_a', 'Book A.epub')],
          // fid_b has no .epub → hasContent false.
          'fid_b': <AssetEntry>[_epub('cover_b', 'cover.jpg')],
        },
      );
      final client =
          CloudRemoteBookClient(backend: backend, rootFolderId: 'root');

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books, hasLength(2));
      final RemoteBookInfo a = books.firstWhere((b) => b.title == 'Book A');
      final RemoteBookInfo b = books.firstWhere((b) => b.title == 'Book B');
      expect(a.bookKey, 'fid_a');
      expect(a.downloadId, 'fid_a'); // downloadId == bookKey == folderId
      expect(a.hasContent, isTrue);
      expect(a.hasCover, isFalse);
      expect(a.coverUrl, isNull);
      expect(a.hasAudiobook, isFalse);
      expect(b.bookKey, 'fid_b');
      expect(b.hasContent, isFalse);
    });

    test('filters reserved namespaces (__dictionaries__/__local_audio__)',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <DriveFile>[
          DriveFile(id: 'dictNs', name: kSyncDictionaryNamespace),
          DriveFile(id: 'audioNs', name: kSyncLocalAudioNamespace),
          DriveFile(id: 'fid_real', name: 'Real Book'),
        ],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_real': <AssetEntry>[_epub('asset_real', 'Real Book.epub')],
        },
      );
      final client =
          CloudRemoteBookClient(backend: backend, rootFolderId: 'root');

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books.map((b) => b.title), <String>['Real Book']);
      // 内容探测不应被浪费在保留区上。
      expect(backend.listChildrenCalls, isNot(contains('dictNs')));
      expect(backend.listChildrenCalls, isNot(contains('audioNs')));
      expect(backend.listChildrenCalls, contains('fid_real'));
      // cacheBookFolderIds 只收到过滤后的书文件夹。
      expect(backend.cachedFolders.map((f) => f.id), <String>['fid_real']);
    });

    test('content probe is fail-open when listChildren throws', () async {
      final backend = _ControllableSyncBackend(
        folders: <DriveFile>[DriveFile(id: 'fid_x', name: 'Flaky Book')],
        childrenByFolder: const <String, List<AssetEntry>>{},
        throwOnListChildrenFor: <String>{'fid_x'},
      );
      final client =
          CloudRemoteBookClient(backend: backend, rootFolderId: 'root');

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books.single.hasContent, isTrue,
          reason: '瞬时列举失败不应隐藏真实远端书（fail-open）');
    });

    test('content probe respects concurrency cap (≤ contentProbeConcurrency)',
        () async {
      final List<DriveFile> many = <DriveFile>[
        for (int i = 0; i < 10; i++) DriveFile(id: 'fid_$i', name: 'Book $i'),
      ];
      final backend = _ControllableSyncBackend(
        folders: many,
        childrenByFolder: <String, List<AssetEntry>>{
          for (final DriveFile f in many)
            f.id: <AssetEntry>[_epub('a_${f.id}', '${f.name}.epub')],
        },
        listChildrenDelay: const Duration(milliseconds: 20),
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        contentProbeConcurrency: 3,
      );

      await client.listRemoteBooks();

      expect(backend.maxConcurrentListChildren, lessThanOrEqualTo(3));
      expect(backend.maxConcurrentListChildren, greaterThan(1),
          reason: '应真并发，不是串行');
      expect(backend.listChildrenCalls, hasLength(10));
    });
  });

  group('CloudRemoteBookClient.getRemoteBook', () {
    test('downloads first .epub asset via getAsset, no second import',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <DriveFile>[DriveFile(id: 'fid_dl', name: 'DL Book')],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_dl': <AssetEntry>[
            _epub('cover', 'cover.jpg'),
            _epub('epub_asset', 'DL Book.epub'),
          ],
        },
      );
      final client =
          CloudRemoteBookClient(backend: backend, rootFolderId: 'root');
      final Directory tmp =
          Directory.systemTemp.createTempSync('cloud_remote_book_dl');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final File dest = File('${tmp.path}/out.epub');

      final List<double> progress = <double>[];
      await client.getRemoteBook('fid_dl', dest, onProgress: progress.add);

      // 只 getAsset 下载，绝不二次导入（无 EpubImporter / importRemoteBookFolder）。
      expect(backend.getAssetCalls, <String>['epub_asset']);
      expect(dest.existsSync(), isTrue);
      expect(await dest.readAsBytes(), <int>[1, 2, 3]);
      expect(progress, isNotEmpty);
    });

    test('throws when folder has no .epub content', () async {
      final backend = _ControllableSyncBackend(
        folders: <DriveFile>[DriveFile(id: 'fid_empty', name: 'Empty')],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_empty': <AssetEntry>[_epub('cover', 'cover.jpg')],
        },
      );
      final client =
          CloudRemoteBookClient(backend: backend, rootFolderId: 'root');
      final Directory tmp =
          Directory.systemTemp.createTempSync('cloud_remote_book_empty');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      await expectLater(
        client.getRemoteBook('fid_empty', File('${tmp.path}/x.epub')),
        throwsA(isA<SyncBackendError>()),
      );
      expect(backend.getAssetCalls, isEmpty);
    });
  });
}
