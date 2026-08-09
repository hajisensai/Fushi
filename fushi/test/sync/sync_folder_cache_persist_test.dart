import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2657 ②：`_persistDriveCache` 每本书都被调一次，旧实现每次都
/// `jsonEncode` 整张书名→folderId 映射表 + upsert，外加一次 `setRootFolderId`。
/// 稳态（所有书都缓存命中）下这张表一字不变，N 本书就白写 O(N²) 字节。
///
/// 修法是脏判定，**不是**批量落盘：内容真变就照旧立刻写（崩溃安全语义不变），
/// 内容没变才跳过。三条用例分别钉住：没变不写 / 变了立刻写 / 尾斜杠自愈仍会写。
class _StableFolderBackend implements SyncBackend {
  _StableFolderBackend({this.normalizeTrailingSlash = false});

  /// 模拟路径式后端（WebDAV / 互联）在 `restoreCache` 里的尾斜杠归一化（BUG-845）。
  final bool normalizeTrailingSlash;

  final Map<String, String> _folders = <String, String>{};
  String? _root;

  String _normalize(String id) =>
      normalizeTrailingSlash && !id.endsWith('/') ? '$id/' : id;

  @override
  Future<String> findOrCreateRootFolder() async => _root ??= _normalize('root');

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      _folders[bookTitle] ??= _normalize('folder-$bookTitle');

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  void clearCache() {
    _root = null;
    _folders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _root = rootFolderId == null ? null : _normalize(rootFolderId);
    titleToFolderId?.forEach((String title, String id) {
      _folders[title] = _normalize(id);
    });
  }

  @override
  String? get cachedRootFolderId => _root;

  @override
  Map<String, String> get cachedFolderIds =>
      Map<String, String>.unmodifiable(_folders);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<EpubBookRow> _insertBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: '[]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((r) => r.title == title);
}

void main() {
  test('an unchanged folder cache is not rewritten for every book', () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await repo.setRootFolderId('root');
    await repo.setFolderCache(<String, String>{
      'Book1': 'folder-Book1',
      'Book2': 'folder-Book2',
    });
    final EpubBookRow book1 = await _insertBook(db, 'Book1');
    final EpubBookRow book2 = await _insertBook(db, 'Book2');

    final backend = _StableFolderBackend();
    final SyncManager manager = SyncManager(db: db, backend: backend);

    await manager.syncBook(
      book: book1,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    // 从这一刻起磁盘上放的是哨兵值。缓存内容没有任何变化，后续同步不许再碰这两行。
    // 无条件重写的旧实现会把哨兵冲掉。
    await repo.setRootFolderId('sentinel-root');
    await repo.setFolderCache(<String, String>{'SENTINEL': 'untouched'});

    await manager.syncBook(
      book: book2,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(
        await repo.getFolderCache(), <String, String>{'SENTINEL': 'untouched'},
        reason: '映射表一字未变时不许重写整表');
    expect(await repo.getRootFolderId(), 'sentinel-root',
        reason: '根 folderId 未变时不许重写');
  });

  test('a newly learned folder id is persisted before that book returns',
      () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    final EpubBookRow book1 = await _insertBook(db, 'Book1');
    final EpubBookRow book2 = await _insertBook(db, 'Book2');

    final backend = _StableFolderBackend();
    final SyncManager manager = SyncManager(db: db, backend: backend);

    await manager.syncBook(
      book: book1,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    // 崩溃安全：脏判定不得退化成「攒到整轮结束再落盘」。第一本书返回时，它的
    // folderId 必须已经在磁盘上——此刻进程被杀也不会丢。
    expect(await repo.getRootFolderId(), 'root');
    expect(
        await repo.getFolderCache(), <String, String>{'Book1': 'folder-Book1'});

    await manager.syncBook(
      book: book2,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(await repo.getFolderCache(), <String, String>{
      'Book1': 'folder-Book1',
      'Book2': 'folder-Book2',
    });
  });

  test('a slash-less persisted folder id still self-heals on the next persist',
      () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    // 被污染的持久化缓存（某些 WebDAV 服务器的 PROPFIND href 没有尾斜杠，BUG-845）。
    await repo.setRootFolderId('root');
    await repo.setFolderCache(<String, String>{'Book1': 'folder-Book1'});
    final EpubBookRow book1 = await _insertBook(db, 'Book1');

    final backend = _StableFolderBackend(normalizeTrailingSlash: true);
    final SyncManager manager = SyncManager(db: db, backend: backend);

    await manager.syncBook(
      book: book1,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    // 脏判定基线必须取**磁盘原值**而不是 restoreCache 归一化后的值，否则自愈写回
    // 被判成「没变」而永远不落盘，磁盘上的污染值就再也清不掉。
    expect(await repo.getFolderCache(),
        <String, String>{'Book1': 'folder-Book1/'});
    expect(await repo.getRootFolderId(), 'root/');
  });
}
