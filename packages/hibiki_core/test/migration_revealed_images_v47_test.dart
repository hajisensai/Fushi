import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 图片防剧透遮罩揭开状态持久化（BUG-898）：建表迁移 revealed_images（v45 -> v47）守护。
///
/// 覆盖：
/// ① v45 -> v47 升级：建出 revealed_images，且迁移落在当前 schema 版本（活值断言，
///    不随后续 bump 变 stale）。空表 = 全部图片保持遮罩 = 行为与旧版一致
///    （Never break userspace，无损迁移）。
/// ② fresh DB：onCreate 的 createAll 已含新表，markImageRevealed / getRevealedImageKeys
///    往返正确，且按 bookKey 隔离。
///
/// 沿用 migration_collection_tags_v43_test 的 raw-seed 范式：from=45 会跳过所有 from<45
/// 的 ladder 步，`if (from < 46)`（epub_books.completedAt 有 _tableExists 守卫，裸 seed 无表故跳过）与 `if (from < 47)` 的 createTable(revealedImages) 会跑，故最小 seed
/// 只需 `PRAGMA user_version = 45`（revealed_images 的 FK 指向 epub_books 在 CREATE TABLE
/// 时不要求目标表已存在，纯 select 也不触发 FK 检查）。

HibikiDatabase _openMigratedFromV45() {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');
        raw.execute('PRAGMA user_version = 45');
      },
    ),
  );
}

void main() {
  test('v45 -> v47 creates revealed_images, lands on current version, empty',
      () async {
    final HibikiDatabase db = _openMigratedFromV45();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');
    // revealed_images 自 v47 引入；断言下界而非瞬时值，避免后续 bump 拖 stale。
    expect(db.schemaVersion, greaterThanOrEqualTo(47),
        reason: 'revealed_images 自 v47 引入，schema 版本不应回退到其之前');

    // 建表成功且可查：空表 = 无揭开记录 = 全部遮罩（行为与旧版一致）。
    expect(await db.getRevealedImageKeys('any-book'), <String>{},
        reason: '旧库升级后空表 = 全部图片保持遮罩');
  });

  test('fresh DB round-trips revealed image keys, isolated per book', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(db.schemaVersion, greaterThanOrEqualTo(47));

    await db.markImageRevealed('book-a', 'OEBPS/images/foo.jpg', 1000);
    await db.markImagesRevealed(
        'book-a', <String>['OEBPS/images/bar.png', 'cover.svg'], 2000);
    await db.markImageRevealed('book-b', 'OEBPS/images/foo.jpg', 3000);

    expect(
      await db.getRevealedImageKeys('book-a'),
      <String>{'OEBPS/images/foo.jpg', 'OEBPS/images/bar.png', 'cover.svg'},
    );
    expect(await db.getRevealedImageKeys('book-b'),
        <String>{'OEBPS/images/foo.jpg'},
        reason: '不同书的相同 imageKey 各自独立，互不影响');

    // 幂等：重复揭开同 key 刷新时间戳、不产生重复行。
    await db.markImageRevealed('book-a', 'cover.svg', 9999);
    expect((await db.getRevealedImageKeys('book-a')).length, 3);
  });
}
