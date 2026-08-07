/// 删除传播墓碑（显式确认式）DB 层测试：写墓碑、重加清碑、发布标记。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  late FushiDatabase db;
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
    await repo.deleteVideoBook('video/v1', scope: DeleteScope.syncEverywhere);
    expect(await db.getSyncDeletionTombstonesOfType('video'), hasLength(1));
    // 重新加入同 uid → 清碑。
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/v1',
      title: 'V1',
      videoPath: '/tmp/v1.mp4',
    ));
    expect(await db.getSyncDeletionTombstonesOfType('video'), isEmpty);
  });

  test('取消收藏写 favoriteword 墓碑；重新收藏清碑', () async {
    await db.addFavoriteWord(
      expression: '猫',
      reading: 'ねこ',
      glossary: 'cat',
      sourceType: 'reader',
      dateKey: '2026-07-23',
    );
    // 取消收藏（默认 propagateDeletion=true）→ 写墓碑。
    final int removed = await db.removeFavoriteWord(
      expression: '猫',
      reading: 'ねこ',
      sourceType: 'reader',
    );
    expect(removed, 1);
    final favs = await db.getSyncDeletionTombstonesOfType('favoriteword');
    expect(favs, hasLength(1));
    expect(favs.single.itemKey,
        FushiDatabase.favoriteWordItemKey('猫', 'ねこ', 'reader'));
    // 重新收藏 → 清碑。
    await db.addFavoriteWord(
      expression: '猫',
      reading: 'ねこ',
      glossary: 'cat',
      sourceType: 'reader',
      dateKey: '2026-07-23',
    );
    expect(await db.getSyncDeletionTombstonesOfType('favoriteword'), isEmpty);
  });

  test('propagateDeletion:false 不写墓碑', () async {
    await db.addFavoriteWord(
      expression: '犬',
      reading: 'いぬ',
      glossary: 'dog',
      sourceType: 'reader',
      dateKey: '2026-07-23',
    );
    await db.removeFavoriteWord(
      expression: '犬',
      reading: 'いぬ',
      sourceType: 'reader',
      propagateDeletion: false,
    );
    expect(await db.getSyncDeletionTombstonesOfType('favoriteword'), isEmpty);
  });

  FavoriteSentence mkSentence({
    String? id,
    String text = '猫が好き',
    String? bookKey = 'a',
    int? sectionIndex = 0,
    int? normCharOffset = 5,
  }) =>
      FavoriteSentence(
        id: id,
        text: text,
        bookTitle: 'BookA',
        bookKey: bookKey,
        sectionIndex: sectionIndex,
        normCharOffset: normCharOffset,
        createdAt: DateTime.fromMillisecondsSinceEpoch(100),
      );

  test('取消收藏句 removeById 写 favoritesentence 墓碑；重新收藏清碑', () async {
    final repo = FavoriteSentenceRepository(db);
    final FavoriteSentence s = mkSentence(id: 'hl_1');
    await repo.add(s);
    await repo.removeById('hl_1');
    final rows = await db.getSyncDeletionTombstonesOfType('favoritesentence');
    expect(rows, hasLength(1));
    expect(rows.single.itemKey, FavoriteSentenceRepository.itemKeyOf(s));
    // 重新收藏同内容 → 清碑（清的是内容键，与 id 无关）。
    await repo.add(mkSentence(id: 'hl_2'));
    expect(
        await db.getSyncDeletionTombstonesOfType('favoritesentence'), isEmpty);
  });

  test('removeByContent 写墓碑；propagateDeletion:false 不写', () async {
    final repo = FavoriteSentenceRepository(db);
    await repo.add(mkSentence(id: 'hl_c1'));
    await repo.removeByContent(
      text: '猫が好き',
      bookKey: 'a',
      sectionIndex: 0,
      normCharOffset: 5,
    );
    expect(await db.getSyncDeletionTombstonesOfType('favoritesentence'),
        hasLength(1));

    await db.clearSyncDeletionTombstone(
        'favoritesentence', FavoriteSentenceRepository.itemKeyOf(mkSentence()));
    await repo.add(mkSentence(id: 'hl_c2'));
    await repo.removeByContent(
      text: '猫が好き',
      bookKey: 'a',
      sectionIndex: 0,
      normCharOffset: 5,
      propagateDeletion: false,
    );
    expect(
        await db.getSyncDeletionTombstonesOfType('favoritesentence'), isEmpty);
  });

  test('removeByItemKey 删本地 + 写墓碑（接收端确认路径）', () async {
    final repo = FavoriteSentenceRepository(db);
    final FavoriteSentence s = mkSentence(id: 'hl_k1');
    await repo.add(s);
    final String key = FavoriteSentenceRepository.itemKeyOf(s);
    await repo.removeByItemKey(key);
    expect(await repo.getAll(), isEmpty);
    final rows = await db.getSyncDeletionTombstonesOfType('favoritesentence');
    expect(rows.single.itemKey, key);
  });

  test('清空收藏句为每条写墓碑', () async {
    final repo = FavoriteSentenceRepository(db);
    await repo.add(mkSentence(id: 'hl_a', text: '一', normCharOffset: 1));
    await repo.add(mkSentence(id: 'hl_b', text: '二', normCharOffset: 2));
    await repo.clear();
    expect(await repo.getAll(), isEmpty);
    expect(await db.getSyncDeletionTombstonesOfType('favoritesentence'),
        hasLength(2));
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
