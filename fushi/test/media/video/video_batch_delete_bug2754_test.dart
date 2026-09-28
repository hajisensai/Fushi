// BUG-2754：视频库批量删除——本地花絮外键冲突删不掉 + 逐条回收 O(N²)。
//
// 仓库层（[VideoBookRepository.deleteVideoBooksAndReclaimAssets]）与 UI 入口
// （[deleteVideoBooksWithDecision]）的行为钉子：
// ① 被挂成本地花絮的视频能删；
// ② 某一条删不掉不拖累其余条，失败条数如实回传；
// ③ 回收阶段的全表读取次数与被删条数无关；
// ④ 删除后只在空闲页占比够大时才整库 VACUUM。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// 数全表读取次数的仓库：`listAll` 是回收阶段幸存行引用集的唯一来源。
class _CountingRepository extends VideoBookRepository {
  _CountingRepository(super.db);

  int listAllCalls = 0;

  @override
  Future<List<VideoBookRow>> listAll() {
    listAllCalls++;
    return super.listAll();
  }
}

/// 数全表附加图读取次数的 DB。
class _CountingDatabase extends FushiDatabase {
  _CountingDatabase() : super.forTesting(NativeDatabase.memory());

  int allMediaImagesCalls = 0;

  @override
  Future<List<MediaImageRow>> getAllMediaImages() {
    allMediaImagesCalls++;
    return super.getAllMediaImages();
  }
}

Future<void> _insertVideo(FushiDatabase db, String uid) => db.upsertVideoBook(
  VideoBooksCompanion.insert(
    bookUid: uid,
    title: uid,
    videoPath: 'D:/Videos/$uid.mkv',
  ),
);

/// 让某一行的删除必然失败：真实 SQLite 约束失败的最小替身（与 BUG-2754 原始
/// 故障同一形态——语句在事务里抛 SqliteException）。
Future<void> _makeUndeletable(FushiDatabase db, String uid) =>
    db.customStatement(
      'CREATE TRIGGER block_delete_$uid BEFORE DELETE ON video_books '
      "WHEN old.book_uid = '$uid' BEGIN SELECT RAISE(ABORT, 'blocked'); END",
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('删被挂成本地花絮的视频：成功、花絮行随之消失（原来 CHECK 失败整批回滚）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    await _insertVideo(db, 'movie');
    await _insertVideo(db, 'movie-extra');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('movie'),
        mediaType: 'movie',
        title: 'Movie',
        updatedAt: 1,
      ),
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'local:movie-extra',
        workId: workId,
        bookUid: const Value<String?>('movie-extra'),
        kind: 'featurette',
        sourceKind: 'local',
        title: 'Extra',
        updatedAt: 1,
      ),
    );

    final int deleted = await repo.deleteVideoBooksAndReclaimAssets(<String>[
      'movie-extra',
    ], compactDatabase: false);

    expect(deleted, 1);
    expect(await repo.getByBookUid('movie-extra'), isNull);
    expect(await db.getVideoMetadataExtras(workId), isEmpty);
    expect(await repo.getByBookUid('movie'), isNotNull);
  });

  test('某一条删不掉：其余照删，失败条目留在库里并随异常回传', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    for (final String uid in <String>['a', 'bad', 'c']) {
      await _insertVideo(db, uid);
    }
    await _makeUndeletable(db, 'bad');

    Object? thrown;
    try {
      await repo.deleteVideoBooksAndReclaimAssets(
        <String>['a', 'bad', 'c'],
        scope: DeleteScope.syncEverywhere,
        compactDatabase: false,
      );
    } catch (e) {
      thrown = e;
    }

    expect(thrown, isA<VideoBooksDeleteException>());
    final VideoBooksDeleteException error =
        thrown! as VideoBooksDeleteException;
    expect(error.deletedCount, 2);
    expect(
      error.failures.map((VideoBookDeleteFailure f) => f.bookUid),
      <String>['bad'],
    );
    expect(await repo.getByBookUid('a'), isNull);
    expect(await repo.getByBookUid('c'), isNull);
    expect(await repo.getByBookUid('bad'), isNotNull);
    final Set<String> tombstoned = <String>{
      for (final SyncDeletionTombstoneRow row
          in await db.getSyncDeletionTombstones())
        if (row.mediaType == SyncTombstoneKind.video.dbValue) row.itemKey,
    };
    expect(tombstoned, <String>{'a', 'c'}, reason: '只给真删掉的行记同步墓碑');
  });

  test('UI 入口把部分失败折成 result.failed，不再向页面抛出', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    for (final String uid in <String>['a', 'bad']) {
      await _insertVideo(db, uid);
    }
    await _makeUndeletable(db, 'bad');
    bool reachedAfterDelete = false;

    final VideoLibraryDeleteResult result = await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['a', 'bad'],
      decision: const DeleteDecision(scope: DeleteScope.keepLocalOnly),
      compactDatabase: false,
      afterDeleteBeforeReclaim: () async => reachedAfterDelete = true,
    );

    expect(result.deleted, 1);
    expect(result.failed.map((VideoBookDeleteFailure f) => f.bookUid), <String>[
      'bad',
    ]);
    expect(reachedAfterDelete, isTrue, reason: '页面靠这个回调退出多选、刷新；部分失败也必须走到');
  });

  test('回收阶段全表读取次数与被删条数无关（原来每条各读一遍 = O(N²)）', () async {
    Future<({int listAll, int mediaImages})> readsFor(int n) async {
      final _CountingDatabase db = _CountingDatabase();
      addTearDown(db.close);
      final _CountingRepository repo = _CountingRepository(db);
      final List<String> uids = <String>[for (int i = 0; i < n; i++) 'v$i'];
      for (final String uid in <String>[...uids, 'keep']) {
        await _insertVideo(db, uid);
      }
      repo.listAllCalls = 0;
      db.allMediaImagesCalls = 0;
      final int deleted = await repo.deleteVideoBooksAndReclaimAssets(
        uids,
        compactDatabase: false,
      );
      expect(deleted, n);
      expect(await repo.getByBookUid('keep'), isNotNull);
      return (listAll: repo.listAllCalls, mediaImages: db.allMediaImagesCalls);
    }

    final ({int listAll, int mediaImages}) one = await readsFor(1);
    final ({int listAll, int mediaImages}) many = await readsFor(40);
    expect(many.listAll, one.listAll);
    expect(many.mediaImages, one.mediaImages);
    expect(one.listAll, lessThanOrEqualTo(1));
    expect(one.mediaImages, lessThanOrEqualTo(2));
  });

  test('删除后只有空闲页占比够大才整库 VACUUM', () {
    expect(
      VideoBookRepository.shouldVacuumAfterVideoDelete(
        freelistPages: 10,
        pageCount: 10000,
      ),
      isFalse,
      reason: '删一两条就重写整个大库是 BUG-2754 的慢因之一',
    );
    expect(
      VideoBookRepository.shouldVacuumAfterVideoDelete(
        freelistPages: 2500,
        pageCount: 10000,
      ),
      isTrue,
    );
    expect(
      VideoBookRepository.shouldVacuumAfterVideoDelete(
        freelistPages: 0,
        pageCount: 0,
      ),
      isFalse,
    );
  });

  test('compactAfterVideoDeleteBestEffort 在真实库上跑通', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    await _insertVideo(db, 'v');
    await repo.deleteVideoBook('v');
    await repo.compactAfterVideoDeleteBestEffort();
    expect(await repo.listAll(), isEmpty);
  });
}
