import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

// 快照路径与逐本列举路径必须**给出完全相同的同步方向**（TODO-2656）。
//
// 这是整个改动的安全性所在。它不是"跳过得对不对"的问题——新设计里根本没有跳过：
// 每本书照常走同一套判定，只是那批远端文件名的来源不同。所以正确性判据就一条：
// 换个来源，结论一个字都不能变。
//
// 断言方式是**同一组输入跑两遍**（一遍喂快照、一遍让后端逐本列举），比对方向与
// 网络调用次数。只断言"结果对"是不够的：那样两条路各自算错成同一个值也会通过。

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 逐本列举后端：按书文件夹名返回预置的远端文件，并数清被问了多少次。
class _PerBookBackend implements SyncBackend {
  _PerBookBackend(this.remote);

  /// 书文件夹名 → 该书的远端 progress 文件名（null = 远端没有）。
  final Map<String, String?> remote;

  int listSyncFilesCalls = 0;
  final List<String> exported = <String>[];

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      'folder/$bookTitle';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    final String title = folderId.substring('folder/'.length);
    final String? name = remote[title];
    return SyncFileTrio(
      progress: name == null ? null : SyncFileRef(id: 'id-$title', name: name),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final String title = fileId.substring('id-'.length);
    final String name = remote[title]!;
    final List<String> parts =
        name.substring(0, name.length - '.json'.length).split('_');
    return TtuProgress(
      dataId: 0,
      exploredCharCount: (double.parse(parts[4]) * 1000).round(),
      progress: double.parse(parts[4]),
      lastBookmarkModified: int.parse(parts[3]),
    );
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exported.add(folderId.substring('folder/'.length));
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
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

RemoteListingSnapshot _snapshotOf(Map<String, String?> remote) {
  final RemoteListingBuilder b = RemoteListingBuilder();
  for (final MapEntry<String, String?> e in remote.entries) {
    b.addFolder(e.key);
    // 每本书都先放一个无关文件：三件套必须靠前缀认出来。若实现改成「取第一个」，
    // 快照路与逐本路就会对同一本书给出不同的 progress，等价性断言立刻失败。
    b.addEntry(parentName: e.key, name: '${e.key}.epub', id: 'epub-${e.key}');
    if (e.value != null) {
      b.addEntry(parentName: e.key, name: e.value!, id: 'id-${e.key}');
    }
  }
  return b.build();
}

/// [baseline] = 共同祖先（上次双方达成一致的进度时间戳）。同步过一次之后它必然存在；
/// 缺了它、且两边时间戳又不同，既有的三方判定会正确地报 conflict 而不是自动选边。
Future<void> _seedBook(
  HibikiDatabase db, {
  required String title,
  int? updatedAt,
  int normCharOffset = 5000,
  int? baseline,
}) async {
  await db.into(db.epubBooks).insert(EpubBooksCompanion.insert(
        bookKey: 'key-$title',
        title: title,
        epubPath: '/tmp/$title.epub',
        extractDir: '/tmp/$title',
        chapterCount: 1,
        chaptersJson: '[{"title":"c1","characters":1000}]',
        importedAt: 1,
      ));
  if (updatedAt != null) {
    await db.upsertReaderPosition(ReaderPositionsCompanion(
      bookKey: Value<String>('key-$title'),
      sectionIndex: const Value<int>(0),
      normCharOffset: Value<int>(normCharOffset),
      updatedAt: Value<int>(updatedAt),
    ));
  }
  if (baseline != null) {
    await db.setSyncBaseline(title, 'progress', baseline);
  }
}

Future<List<SyncBookResult>> _run(
  HibikiDatabase db,
  SyncBackend backend, {
  RemoteListingSnapshot? listing,
}) =>
    SyncManager(db: db, backend: backend).syncAllBooks(
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
      listing: listing,
    );

/// 同一场景跑两遍：一遍喂快照、一遍逐本列举，返回两边的方向序列。
Future<({List<SyncResult> viaSnapshot, List<SyncResult> viaPerBook, int calls})>
    _bothPaths(
  Map<String, String?> remote,
  Future<void> Function(HibikiDatabase db) seed,
) async {
  final HibikiDatabase dbA = _testDb();
  addTearDown(dbA.close);
  await seed(dbA);
  final _PerBookBackend backendA = _PerBookBackend(remote);
  final List<SyncBookResult> a =
      await _run(dbA, backendA, listing: _snapshotOf(remote));

  final HibikiDatabase dbB = _testDb();
  addTearDown(dbB.close);
  await seed(dbB);
  final _PerBookBackend backendB = _PerBookBackend(remote);
  final List<SyncBookResult> b = await _run(dbB, backendB);

  return (
    viaSnapshot: a.map((SyncBookResult r) => r.direction).toList(),
    viaPerBook: b.map((SyncBookResult r) => r.direction).toList(),
    calls: backendA.listSyncFilesCalls,
  );
}

void main() {
  test('双方一致：两条路都判 synced，快照路零列举请求', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': 'progress_1_6_1000_0.5.json'},
      (HibikiDatabase db) => _seedBook(db, title: 'Book A', updatedAt: 1000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.synced]);
    expect(r.calls, 0, reason: '这正是改动前每本书都要付的那次往返');
  });

  test('本地更新：两条路都判 exported', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': 'progress_1_6_1000_0.5.json'},
      (HibikiDatabase db) => _seedBook(db,
          title: 'Book A',
          updatedAt: 2000,
          normCharOffset: 6000,
          baseline: 1000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.exported]);
    expect(r.calls, 0);
  });

  test('远端更新：两条路都判 imported——快照绝不会让这次拉取被跳掉', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': 'progress_1_6_9000_0.9.json'},
      (HibikiDatabase db) =>
          _seedBook(db, title: 'Book A', updatedAt: 1000, baseline: 1000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.imported]);
  });

  test('远端没有 progress：两条路都判 exported', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': null},
      (HibikiDatabase db) => _seedBook(db, title: 'Book A', updatedAt: 1000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.exported]);
  });

  test('两边都没有进度：两条路都判 synced', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': null},
      (HibikiDatabase db) => _seedBook(db, title: 'Book A'),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.synced]);
  });

  test('时间戳相同但分数不同：两条路都按内容 tie-break，结论一致', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': 'progress_1_6_1000_0.1.json'},
      (HibikiDatabase db) =>
          _seedBook(db, title: 'Book A', updatedAt: 1000, normCharOffset: 9000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.exported],
        reason: '同一毫秒，本地读得更远 → 本地胜出');
  });

  test('快照里没有这本书（远端全新）：两条路都判 exported，不会被当成一致', () async {
    // 快照说"没有这个文件夹"与逐本列举一个不存在的文件夹必须同义。若把"快照里查
    // 不到"误当成"双方一致"，一本从没上传过的书就永远传不上去。
    final HibikiDatabase dbA = _testDb();
    addTearDown(dbA.close);
    await _seedBook(dbA, title: 'Book A', updatedAt: 1000);
    final _PerBookBackend backendA = _PerBookBackend(<String, String?>{});
    final List<SyncBookResult> a =
        await _run(dbA, backendA, listing: RemoteListingBuilder().build());

    final HibikiDatabase dbB = _testDb();
    addTearDown(dbB.close);
    await _seedBook(dbB, title: 'Book A', updatedAt: 1000);
    final _PerBookBackend backendB = _PerBookBackend(<String, String?>{});
    final List<SyncBookResult> b = await _run(dbB, backendB);

    expect(a.single.direction, b.single.direction);
    expect(a.single.direction, SyncResult.exported);
    expect(backendA.exported, <String>['Book A']);
  });

  test('多本书混合场景：逐本方向序列完全一致，快照路一次列举都不发', () async {
    final Map<String, String?> remote = <String, String?>{
      'Same': 'progress_1_6_1000_0.5.json',
      'LocalNewer': 'progress_1_6_1000_0.5.json',
      'RemoteNewer': 'progress_1_6_9000_0.9.json',
      'RemoteMissing': null,
    };
    final r = await _bothPaths(remote, (HibikiDatabase db) async {
      await _seedBook(db, title: 'Same', updatedAt: 1000, baseline: 1000);
      await _seedBook(db,
          title: 'LocalNewer',
          updatedAt: 2000,
          normCharOffset: 6000,
          baseline: 1000);
      await _seedBook(db,
          title: 'RemoteNewer', updatedAt: 1000, baseline: 1000);
      await _seedBook(db, title: 'RemoteMissing', updatedAt: 1000);
    });

    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[
      SyncResult.synced,
      SyncResult.exported,
      SyncResult.imported,
      SyncResult.exported,
    ]);
    expect(r.calls, 0, reason: '4 本书原本要发 4 次列举');
  });

  test('无共同祖先且双边分叉：两条路都判 conflict（快照不会把冲突吞成一致）', () async {
    final r = await _bothPaths(
      <String, String?>{'Book A': 'progress_1_6_9000_0.9.json'},
      (HibikiDatabase db) => _seedBook(db, title: 'Book A', updatedAt: 1000),
    );
    expect(r.viaSnapshot, r.viaPerBook);
    expect(r.viaSnapshot, <SyncResult>[SyncResult.conflict]);
  });

  test('不传快照（后端不支持）→ 逐本列举，行为与改动前逐字相同', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    await _seedBook(db, title: 'Book A', updatedAt: 1000);
    await _seedBook(db, title: 'Book B', updatedAt: 1000);
    final _PerBookBackend backend = _PerBookBackend(<String, String?>{
      'Book A': 'progress_1_6_1000_0.5.json',
      'Book B': 'progress_1_6_1000_0.5.json',
    });

    await _run(db, backend);
    expect(backend.listSyncFilesCalls, 2);
  });
}
