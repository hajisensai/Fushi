import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_module_gate.dart';
import 'package:fushi_core/fushi_core.dart';

/// 书阶段的逐本循环提前退出（同步模块被关掉的取消检查点 / 鉴权失效）后，列举预取
/// worker 不得再领新活：调用方随即放掉这条通道的后端锁，别的同步接手这个无锁单例，
/// 被丢下的 worker 若还在发列举请求，就是在锁外使用它（反馈 SJeJd5EEZO）。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 每次列举都挂起，直到测试放行；数清一共被问了几次。
class _HeldListingBackend implements SyncBackend {
  _HeldListingBackend(this.titles);

  final List<String> titles;
  int listSyncFilesCalls = 0;
  final List<Completer<void>> held = <Completer<void>>[];

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'folder/$bookTitle';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    final Completer<void> gate = Completer<void>();
    held.add(gate);
    await gate.future;
    return const SyncFileTrio();
  }

  @override
  String? get cachedRootFolderId => 'root';

  @override
  Map<String, String> get cachedFolderIds => <String, String>{
    for (final String t in titles) t: 'folder/$t',
  };

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

void main() {
  test('循环在第一本书前被取消：预取 worker 跑完手上那一个就停，不再领新活', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final List<String> titles = <String>[for (int i = 0; i < 10; i++) 'book$i'];
    for (final String title in titles) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'key-$title',
          title: title,
          epubPath: '/tmp/$title.epub',
          extractDir: '/tmp/$title',
          chapterCount: 1,
          chaptersJson: '[{"title":"c1","characters":1000}]',
          importedAt: 1,
        ),
      );
    }
    final _HeldListingBackend backend = _HeldListingBackend(titles);

    await expectLater(
      SyncManager(db: db, backend: backend).syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
        onBookProgress: (int done, int total, String title) =>
            throw const SyncCancelledException(),
      ),
      throwsA(isA<SyncCancelledException>()),
    );

    final int inFlight = backend.listSyncFilesCalls;
    expect(inFlight, greaterThan(0), reason: '前提：预取已经开工');
    expect(inFlight, lessThan(titles.length));

    // 放行手上那几个；放行后的 worker 不得再领下一本。
    for (int round = 0; round < 3; round++) {
      for (final Completer<void> c in List<Completer<void>>.of(backend.held)) {
        if (!c.isCompleted) c.complete();
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      backend.listSyncFilesCalls,
      inFlight,
      reason: '循环已退出，预取 worker 继续发列举就是在通道锁外使用后端',
    );
  });
}
