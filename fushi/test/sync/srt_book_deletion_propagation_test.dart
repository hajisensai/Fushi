/// TODO-2470 死角①：纯字幕书勾了「从所有设备删除」完全无效。
///
/// 根因：书架删 standalone SRT（`bookKey` 空）时只走 `SrtBookRepository.delete(uid)`，
/// 而它当时没有传播参数、从不写墓碑——用户选的 `DeleteScope` 被静默丢弃。srt-backed
/// 的字幕书（`bookKey` 非空）另有 `ReaderFushiSource.deleteBook` 写 `book` 墓碑，
/// 所以只有纯字幕书这一类失效，恰好对上用户报的症状。
///
/// 本文件盯住修复后的契约：**身份键 = uid ⟺ standalone**，写墓碑与「在库键」两侧
/// 必须用同一条判据，否则要么漏传播、要么同一资产在对端弹两条重复确认。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

SrtBooksCompanion _srt({
  required String uid,
  String bookKey = '',
  String title = 'SRT Book',
}) =>
    SrtBooksCompanion.insert(
      uid: uid,
      title: title,
      srtPath: '/tmp/$uid.srt',
      importedAt: 0,
      bookKey: Value(bookKey),
    );

void main() {
  late FushiDatabase db;
  late SrtBookRepository repo;

  setUp(() async {
    db = _memDb();
    repo = SrtBookRepository(db);
    // AudiobookStorage.deletePersistDir 会解析文档目录；单测里没有 path_provider
    // 平台通道，注入临时目录解析器（该目录不存在，deletePersistDir 直接 no-op）。
    AudiobookStorage.documentsRootResolver =
        () async => Directory.systemTemp.createTemp('srt_tombstone_test');
  });
  tearDown(() async {
    AudiobookStorage.documentsRootResolver = null;
    await db.close();
  });

  Future<List<SyncDeletionTombstoneRow>> srtTombstones() =>
      db.getSyncDeletionTombstonesOfType(SyncTombstoneKind.srtbook.dbValue);

  group('TODO-2470 死角① 纯字幕书删除传播', () {
    test('standalone + propagateDeletion → 写 srtbook 墓碑，itemKey=uid', () async {
      await db.upsertSrtBook(_srt(uid: 'srt/lonely'));

      final int removed =
          await repo.delete('srt/lonely', propagateDeletion: true);

      expect(removed, 1);
      final List<SyncDeletionTombstoneRow> rows = await srtTombstones();
      expect(rows, hasLength(1), reason: '这正是用户报的「纯字幕书勾了完全无效」——修好后必须落一条墓碑');
      expect(rows.single.itemKey, 'srt/lonely');
      expect(rows.single.remotePublishedAt, 0, reason: '新墓碑未发布');
    });

    test('standalone 但 propagateDeletion:false（默认）→ 不写墓碑', () async {
      await db.upsertSrtBook(_srt(uid: 'srt/lonely'));

      await repo.delete('srt/lonely');

      expect(await srtTombstones(), isEmpty,
          reason: '「仅本机」与消费远端标记的路径都绝不能回写墓碑，否则传播成环');
    });

    test('srt-backed（bookKey 非空）即便 propagateDeletion 也不写 srtbook 墓碑', () async {
      await db.upsertSrtBook(_srt(uid: 'srt/paired', bookKey: 'BookA'));

      await repo.delete('srt/paired', propagateDeletion: true);

      expect(await srtTombstones(), isEmpty,
          reason: '它的身份是 bookKey，墓碑由 deleteBook 写成 book 种类；'
              '这里再写一条会让同一资产在对端弹出两条重复的删除确认');
    });

    test('uid 不存在 → 不写墓碑（删了 0 行不该产生传播）', () async {
      await repo.delete('srt/ghost', propagateDeletion: true);
      expect(await srtTombstones(), isEmpty);
    });

    test('重新导入同 uid 的字幕书 → 清墓碑（防「删了又加、墓碑还在」）', () async {
      await db.upsertSrtBook(_srt(uid: 'srt/again'));
      await repo.delete('srt/again', propagateDeletion: true);
      expect(await srtTombstones(), hasLength(1));

      await repo.save(SrtBook()
        ..uid = 'srt/again'
        ..title = 'SRT Book'
        ..srtPath = '/tmp/srt/again.srt'
        ..importedAt = 0
        ..bookKey = '');

      expect(await srtTombstones(), isEmpty);
    });
  });
}
