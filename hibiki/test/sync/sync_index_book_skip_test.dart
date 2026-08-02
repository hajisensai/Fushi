import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_index.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_file_ref.dart';
import 'package:hibiki_core/hibiki_core.dart';

// 增量同步的收益本体（TODO-2656）：一本双方已经一致的书，整本跳过，**一次网络请求
// 都不发**。
//
// 所以这里的断言核心是 `listSyncFilesCalls`——它就是改动前每本书都要付的那次往返。
// 断言「结果是 synced」是不够的：不跳过时结果同样是 synced，只是多花了一次请求。
//
// 另一半同样重要：跳过的判据必须与完整路径**逐条一致**。判据分叉的表现是某些书永远
// 同步不干净或永远被跳过，而两者都不会以异常的形式暴露出来。

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 只实现本测试用得到的部分；其余成员一律走 [noSuchMethod]，被意外调用时立刻炸，
/// 而不是静默返回 null 把问题藏起来。
class _CountingBackend implements SyncBackend {
  /// 改动前每本书都要付的那次远端列举。跳过生效时它必须是 0。
  int listSyncFilesCalls = 0;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      'folder';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    // 这些测试只关心「有没有发出这次请求」，不关心远端返回什么：跳过路径下它压根
    // 不该被调用，走完整路径的用例则以调用次数本身作为断言。
    return const SyncFileTrio();
  }

  @override
  String? get cachedRootFolderId => 'root';

  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected backend call: '
          '${invocation.memberName}');
}

/// 一本 1000 字的单章书；`normCharOffset` 网格与真实实现一致。
Future<EpubBookRow> _seedBook(HibikiDatabase db,
    {required String title}) async {
  await db.into(db.epubBooks).insert(EpubBooksCompanion.insert(
        bookKey: 'key-$title',
        title: title,
        epubPath: '/tmp/$title.epub',
        extractDir: '/tmp/$title',
        chapterCount: 1,
        chaptersJson: '[{"title":"c1","characters":1000}]',
        importedAt: 1,
      ));
  final List<EpubBookRow> books = await db.getAllEpubBooks();
  return books.firstWhere((EpubBookRow b) => b.title == title);
}

Future<List<SyncBookResult>> _run(
  HibikiDatabase db,
  SyncBackend backend, {
  SyncIndexPlan? plan,
}) =>
    SyncManager(db: db, backend: backend).syncAllBooks(
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
      indexPlan: plan,
    );

SyncIndexPlan _plan(
  Map<String, SyncIndexBookEntry> books, {
  bool usable = true,
}) =>
    SyncIndexPlan(
      usable: usable,
      remoteUnchanged: true,
      books: books,
      ownStages: const <String, String>{},
      ownRevision: 1,
      peerRevisions: const <String, int>{},
      forcedFullSweep: false,
    );

void main() {
  test('双方一致 → 整本跳过，零网络请求', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));

    final _CountingBackend backend = _CountingBackend();
    final List<SyncBookResult> results = await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
      }),
    );

    expect(backend.listSyncFilesCalls, 0, reason: '这正是改动前每本书都要付的那次往返');
    expect(results.single.direction, SyncResult.synced);
    expect(results.single.indexAssetKey, 'Book A');
    expect(results.single.indexEntry?.progressAt, 1000,
        reason: '跳过的书要把上一轮的观测原样带进新索引，否则下轮它会掉出索引');
  });

  test('跳过时仍写下共同祖先基线', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));

    await _run(
      db,
      _CountingBackend(),
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
      }),
    );

    // 完整路径的 synced 分支会写这个基线。长期跳过若不写，基线会永远停在旧值，
    // 日后任一端单边一改就被误判成分叉、弹出假冲突。
    expect(await db.getSyncBaseline('Book A', 'progress'), 1000);
  });

  test('双方都没有阅读位置 → 同样跳过（不是「没记录所以要问一次」）', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');

    final _CountingBackend backend = _CountingBackend();
    final List<SyncBookResult> results = await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(),
      }),
    );

    expect(backend.listSyncFilesCalls, 0);
    expect(results.single.direction, SyncResult.synced);
  });

  test('本地时间戳更新 → 不跳过，走完整路径', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(6000),
      updatedAt: Value<int>(2000),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
      }),
    );

    expect(backend.listSyncFilesCalls, 1);
  });

  test('远端时间戳更新 → 不跳过', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 9000, progressFraction: 0.9),
      }),
    );

    expect(backend.listSyncFilesCalls, 1);
  });

  test('时间戳相同但进度分数不同 → 不跳过（对齐完整路径的 tie-break）', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(9000),
      updatedAt: Value<int>(1000),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        // 同一毫秒但读到的位置差很多：完整路径会按内容判方向，跳过判据也必须如此。
        'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.1),
      }),
    );

    expect(backend.listSyncFilesCalls, 1);
  });

  test('索引里没有这本书（新导入）→ 不跳过', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');

    final _CountingBackend backend = _CountingBackend();
    await _run(db, backend, plan: _plan(const <String, SyncIndexBookEntry>{}));

    expect(backend.listSyncFilesCalls, 1, reason: '从没完整同步过的书被跳过就等于永远不上传');
  });

  test('索引不可用 → 一本都不跳过', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(
      db,
      backend,
      plan: _plan(
        const <String, SyncIndexBookEntry>{
          'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
        },
        usable: false,
      ),
    );

    expect(backend.listSyncFilesCalls, 1);
  });

  test('不传 plan（老调用点）→ 行为与改动前逐字相同', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(db, backend);

    expect(backend.listSyncFilesCalls, 1);
  });

  test('多本书各判各的：一致的跳过，变动的照常走', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A');
    await _seedBook(db, title: 'Book B');
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book A'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(1000),
    ));
    await db.upsertReaderPosition(const ReaderPositionsCompanion(
      bookKey: Value<String>('key-Book B'),
      sectionIndex: Value<int>(0),
      normCharOffset: Value<int>(5000),
      updatedAt: Value<int>(7777),
    ));

    final _CountingBackend backend = _CountingBackend();
    await _run(
      db,
      backend,
      plan: _plan(const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
        'Book B': SyncIndexBookEntry(progressAt: 1000, progressFraction: 0.5),
      }),
    );

    expect(backend.listSyncFilesCalls, 1, reason: '只有 Book B 需要问远端');
  });
}
