import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show kSyncDictionaryNamespace, kSyncLocalAudioNamespace;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';

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
  final List<SyncFileRef> folders;

  /// folderId → 子项。缺省视为空文件夹。
  final Map<String, List<AssetEntry>> childrenByFolder;

  /// 对这些 folderId 的 listChildren 抛异常（测 fail-open）。
  final Set<String> throwOnListChildrenFor;

  /// 每次 listChildren 的人为延迟（让并发可观测）。
  final Duration listChildrenDelay;

  final List<String> listChildrenCalls = <String>[];
  final List<String> getAssetCalls = <String>[];
  final List<SyncFileRef> cachedFolders = <SyncFileRef>[];

  int _inFlightListChildren = 0;
  int maxConcurrentListChildren = 0;

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async => folders;

  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {
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
    SyncCoverDataProvider? readCoverData,
  }) async =>
      throw UnimplementedError();
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
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
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
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

/// Fake：对 [failFirstFor] 里的 folderId 首次 listChildren 抛异常、之后成功返回
/// [epubChildById]。用于验证「一次瞬时失败 → 有界重试成功 → 真书不被误藏」。
class _FlakyThenOkSyncBackend extends _ControllableSyncBackend {
  _FlakyThenOkSyncBackend({
    required super.folders,
    required Map<String, List<AssetEntry>> epubChildById,
    required this.failFirstFor,
  }) : super(childrenByFolder: epubChildById);

  final Set<String> failFirstFor;
  final Map<String, int> _attempts = <String, int>{};

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    listChildrenCalls.add(namespaceId);
    final int attempt = (_attempts[namespaceId] ?? 0);
    _attempts[namespaceId] = attempt + 1;
    if (failFirstFor.contains(namespaceId) && attempt == 0) {
      throw SyncBackendError('transient boom: $namespaceId');
    }
    return childrenByFolder[namespaceId] ?? const <AssetEntry>[];
  }
}

void main() {
  group('CloudRemoteBookClient.listRemoteBooks', () {
    test(
        'maps folders → RemoteBookInfo with bookKey=folderId, hasContent probe',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <SyncFileRef>[
          SyncFileRef(id: 'fid_a', name: 'Book A'),
          SyncFileRef(id: 'fid_b', name: 'Book B'),
        ],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_a': <AssetEntry>[_epub('asset_a', 'Book A.epub')],
          // fid_b has no .epub → hasContent false.
          'fid_b': <AssetEntry>[_epub('cover_b', 'cover.jpg')],
        },
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
      );

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books, hasLength(2));
      final RemoteBookInfo a = books.firstWhere((b) => b.title == 'Book A');
      final RemoteBookInfo b = books.firstWhere((b) => b.title == 'Book B');
      expect(a.bookKey, 'fid_a');
      expect(a.downloadId, 'fid_a'); // downloadId == bookKey == folderId
      expect(a.hasContent, isTrue);
      expect(a.hasEmbeddedCover, isFalse);
      expect(a.coverUrl, isNull);
      expect(a.hasAudiobook, isFalse);
      expect(b.bookKey, 'fid_b');
      expect(b.hasContent, isFalse);
    });

    test('filters reserved namespaces (__dictionaries__/__local_audio__)',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <SyncFileRef>[
          SyncFileRef(id: 'dictNs', name: kSyncDictionaryNamespace),
          SyncFileRef(id: 'audioNs', name: kSyncLocalAudioNamespace),
          SyncFileRef(id: 'fid_real', name: 'Real Book'),
        ],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_real': <AssetEntry>[_epub('asset_real', 'Real Book.epub')],
        },
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
      );

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books.map((b) => b.title), <String>['Real Book']);
      // 内容探测不应被浪费在保留区上。
      expect(backend.listChildrenCalls, isNot(contains('dictNs')));
      expect(backend.listChildrenCalls, isNot(contains('audioNs')));
      expect(backend.listChildrenCalls, contains('fid_real'));
      // cacheBookFolderIds 只收到过滤后的书文件夹。
      expect(backend.cachedFolders.map((f) => f.id), <String>['fid_real']);
    });

    test(
        'content probe is conservative (hasContent=false) when listChildren '
        'keeps throwing (BUG-699 / TODO-1384: no fail-open ghost book)',
        () async {
      final backend = _ControllableSyncBackend(
        folders: <SyncFileRef>[SyncFileRef(id: 'fid_x', name: 'Flaky Book')],
        childrenByFolder: const <String, List<AssetEntry>>{},
        throwOnListChildrenFor: <String>{'fid_x'},
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
        contentProbeRetryBackoff: Duration.zero,
      );

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      // 探测失败（异常/超时）绝不当「有内容」放出——修前 fail-open 会返 true 导致
      // 无内容文件夹作幽灵书闪现。下游 `.where(hasContent)` 据此把它滤掉。
      expect(books.single.hasContent, isFalse,
          reason: '探测失败必须保守视为未确证有内容，不得 fail-open 放出幽灵书');
      // 有界重试：默认重试 1 次 → 每个文件夹探测调用 listChildren 两次后放弃。
      expect(
        backend.listChildrenCalls.where((String c) => c == 'fid_x').length,
        2,
        reason: '失败时按 contentProbeRetries=1 做一次有界重试，仍失败即保守 false',
      );
    });

    test(
        'content probe recovers a real book when a transient failure clears on '
        'retry (BUG-699 / TODO-1384)', () async {
      // 首次列举抛出（瞬时抖动），重试成功并看到 .epub → 真书仍被确证有内容。
      final backend = _FlakyThenOkSyncBackend(
        folders: <SyncFileRef>[
          SyncFileRef(id: 'fid_r', name: 'Recovering Book')
        ],
        epubChildById: <String, List<AssetEntry>>{
          'fid_r': <AssetEntry>[_epub('asset_r', 'Recovering Book.epub')],
        },
        failFirstFor: <String>{'fid_r'},
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
        contentProbeRetryBackoff: Duration.zero,
      );

      final List<RemoteBookInfo> books = await client.listRemoteBooks();

      expect(books.single.hasContent, isTrue, reason: '一次瞬时失败后重试成功，真书不应被误藏');
    });

    test('content probe respects concurrency cap (≤ contentProbeConcurrency)',
        () async {
      final List<SyncFileRef> many = <SyncFileRef>[
        for (int i = 0; i < 10; i++) SyncFileRef(id: 'fid_$i', name: 'Book $i'),
      ];
      final backend = _ControllableSyncBackend(
        folders: many,
        childrenByFolder: <String, List<AssetEntry>>{
          for (final SyncFileRef f in many)
            f.id: <AssetEntry>[_epub('a_${f.id}', '${f.name}.epub')],
        },
        listChildrenDelay: const Duration(milliseconds: 20),
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
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
        folders: <SyncFileRef>[SyncFileRef(id: 'fid_dl', name: 'DL Book')],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_dl': <AssetEntry>[
            _epub('cover', 'cover.jpg'),
            _epub('epub_asset', 'DL Book.epub'),
          ],
        },
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
      );
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
        folders: <SyncFileRef>[SyncFileRef(id: 'fid_empty', name: 'Empty')],
        childrenByFolder: <String, List<AssetEntry>>{
          'fid_empty': <AssetEntry>[_epub('cover', 'cover.jpg')],
        },
      );
      final client = CloudRemoteBookClient(
        backend: backend,
        rootFolderId: 'root',
        backendType: SyncBackendType.webDav,
      );
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
