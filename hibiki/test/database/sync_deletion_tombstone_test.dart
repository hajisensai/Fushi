/// 删除传播墓碑（显式确认式）DB 层测试：写墓碑、重加清碑、发布标记。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

void main() {
  late HibikiDatabase db;
  setUp(() => db = _memDb());
  tearDown(() => db.close());

  test('写墓碑 + 按类型/全量读', () async {
    await db.writeSyncDeletionTombstone('book', 'BookA', 100);
    await db.writeSyncDeletionTombstone('video', 'video/v1', 200);
    expect((await db.getSyncDeletionTombstones()).length, 2);
    final books = await db.getSyncDeletionTombstonesOfType('book');
    expect(books.single.itemKey, 'BookA');
    expect(books.single.deletedAt, 100);
    expect(books.single.remotePublishedAt, 0);
  });

  test('重新导入同 bookKey 的书清除其墓碑', () async {
    await db.writeSyncDeletionTombstone('book', 'BookA', 100);
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'BookA',
      title: 'BookA',
      epubPath: '/tmp/a.epub',
      extractDir: '/tmp/a',
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    expect(await db.getSyncDeletionTombstonesOfType('book'), isEmpty);
  });

  test('删视频经 repo 写墓碑（仅 syncEverywhere）；重新 upsert 清碑', () async {
    final repo = VideoBookRepository(db);
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/v1',
      title: 'V1',
      videoPath: '/tmp/v1.mp4',
    ));
    // keepLocalOnly（默认）不写传播墓碑。
    await repo.deleteVideoBook('video/v1');
    expect(await db.getSyncDeletionTombstonesOfType('video'), isEmpty);
    // syncEverywhere 才写传播墓碑。
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/v1',
      title: 'V1',
      videoPath: '/tmp/v1.mp4',
    ));
    await repo.deleteVideoBook('video/v1',
        scope: DeleteScope.syncEverywhere);
    expect(await db.getSyncDeletionTombstonesOfType('video'), hasLength(1));
    // 重新加入同 uid → 清碑。
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/v1',
      title: 'V1',
      videoPath: '/tmp/v1.mp4',
    ));
    expect(await db.getSyncDeletionTombstonesOfType('video'), isEmpty);
  });

  test('发布标记 remotePublishedAt', () async {
    await db.writeSyncDeletionTombstone('book', 'BookA', 100);
    await db.markSyncDeletionPublished('book', 'BookA', 500);
    final row = (await db.getSyncDeletionTombstonesOfType('book')).single;
    expect(row.remotePublishedAt, 500);
    // 重复删（写墓碑）会重置发布状态为 0（新一轮删除需重新发布）。
    await db.writeSyncDeletionTombstone('book', 'BookA', 600);
    expect(
        (await db.getSyncDeletionTombstonesOfType('book'))
            .single
            .remotePublishedAt,
        0);
  });

  test('clearSyncDeletionTombstone 显式清除', () async {
    await db.writeSyncDeletionTombstone('localaudio', 'MyLib', 100);
    await db.clearSyncDeletionTombstone('localaudio', 'MyLib');
    expect(await db.getSyncDeletionTombstones(), isEmpty);
  });
}
