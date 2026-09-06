import 'package:drift/drift.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// 同步对比对话框的共享夹具（golden 与排版行为测试共用一份，免得两份 fake 漂移）。
///
/// 场景 [seedCompareScenario]：2 本真分叉冲突 + 1 本本地更新（自动上传）+ 1 本远端
/// 更新（自动下载）+ 1 本远端独有可下载 + 1 个远端独有词典。
const String kCompareChaptersJson = '[{"characters":1000}]';
const String kCompareDictNamespace = 'dicts';

class RemoteBookFixture {
  const RemoteBookFixture({
    required this.folderId,
    this.timestampMs,
    this.fraction,
  });

  final String folderId;
  final int? timestampMs;
  final double? fraction;
}

/// 只实现对比对话框 `_load` 路径会触达的成员；其余经 noSuchMethod 抛出，走到
/// 意料之外的路径就大声失败。
class FakeCompareBackend implements SyncBackend {
  FakeCompareBackend(this.books);

  final Map<String, RemoteBookFixture> books;
  String? _root;
  final Map<String, String> _folders = <String, String>{};

  @override
  Future<String> findOrCreateRootFolder() async => _root = 'root';

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        for (final MapEntry<String, RemoteBookFixture> e in books.entries)
          SyncFileRef(id: e.value.folderId, name: e.key),
      ];

  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    for (final RemoteBookFixture b in books.values) {
      if (b.folderId != folderId || b.timestampMs == null) continue;
      return SyncFileTrio(
        progress: SyncFileRef(
          id: 'progress-$folderId',
          name: progressFileName(b.timestampMs!, b.fraction!),
        ),
      );
    }
    return const SyncFileTrio();
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final RemoteBookFixture b in books.values) {
      if ('progress-${b.folderId}' != fileId) continue;
      return TtuProgress(
        dataId: 0,
        exploredCharCount: (b.fraction! * 1000).round(),
        progress: b.fraction!,
        lastBookmarkModified: b.timestampMs!,
      );
    }
    throw StateError('no payload for $fileId');
  }

  @override
  Future<String> ensureNamespace(String name) async => kCompareDictNamespace;

  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    if (id == kCompareDictNamespace) {
      return const <AssetEntry>[
        AssetEntry(id: 'dict-jmdict', name: 'JMdict.fushidict'),
      ];
    }
    // 远端独有书的文件夹里有 .epub 才可下载。
    return const <AssetEntry>[AssetEntry(id: 'e', name: 'book.epub')];
  }

  @override
  void clearCache() {
    _root = null;
    _folders.clear();
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    _root = rootFolderId;
    if (titleToFolderId != null) _folders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _root;

  @override
  Map<String, String> get cachedFolderIds => _folders;

  /// 删过的远端资产 id（顺序即删除顺序）。
  final List<String> deleted = <String>[];

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    deleted.add(id);
  }

  @override
  void evictFolderId(String folderId) {
    _folders.removeWhere((String _, String v) => v == folderId);
  }

  @override
  Future<bool> get isAuthenticated async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not on the load path');
}

Future<EpubBookRow> seedCompareBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: kCompareChaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

Future<void> seedComparePosition(
  FushiDatabase db,
  String bookUid, {
  required int updatedAt,
  required double fraction,
}) async {
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookUid: Value(bookUid),
    sectionIndex: const Value(0),
    normCharOffset: Value((fraction * 10000).round()),
    updatedAt: Value(updatedAt),
  ));
}

/// 标准场景：见文件头。返回配好的 fake 后端。
Future<FakeCompareBackend> seedCompareScenario(FushiDatabase db) async {
  // 两本真分叉：本地与远端都偏离 base。
  for (final String title in <String>['Conflict A', 'Conflict B']) {
    final EpubBookRow b = await seedCompareBook(db, title);
    await seedComparePosition(db, b.uid, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename(title), 'progress', 50);
  }
  // 本地更新（远端 == base）→ 自动上传。
  final EpubBookRow localNewer = await seedCompareBook(db, 'Local newer');
  await seedComparePosition(db, localNewer.uid, updatedAt: 120, fraction: 0.4);
  await db.setSyncBaseline(sanitizeTtuFilename('Local newer'), 'progress', 100);
  // 远端更新（本地 == base）→ 自动下载。
  final EpubBookRow remoteNewer = await seedCompareBook(db, 'Remote newer');
  await seedComparePosition(db, remoteNewer.uid, updatedAt: 100, fraction: 0.3);
  await db.setSyncBaseline(
      sanitizeTtuFilename('Remote newer'), 'progress', 100);

  return FakeCompareBackend(<String, RemoteBookFixture>{
    'Conflict A': const RemoteBookFixture(
        folderId: 'fa', timestampMs: 130, fraction: 0.7),
    'Conflict B': const RemoteBookFixture(
        folderId: 'fb', timestampMs: 130, fraction: 0.2),
    'Local newer': const RemoteBookFixture(
        folderId: 'fl', timestampMs: 100, fraction: 0.3),
    'Remote newer': const RemoteBookFixture(
        folderId: 'fr', timestampMs: 120, fraction: 0.5),
    'Remote only': const RemoteBookFixture(folderId: 'fo'),
  });
}
