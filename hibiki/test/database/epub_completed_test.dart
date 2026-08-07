import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<String> _insertBook(FushiDatabase db, String key) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/tmp/$key.epub',
        extractDir: '/tmp/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

void main() {
  group('EpubBooks 完成状态（书 / 有声书共用同一列，按 bookKey）', () {
    test('新导入的书未完成', () async {
      final db = await _openDb();
      await _insertBook(db, 'A');
      expect(await db.getCompletedEpubBookKeys(), isEmpty);
      expect((await db.getEpubBook('A'))!.completedAt, isNull);
    });

    test('setEpubBookCompleted 手动标记与取消', () async {
      final db = await _openDb();
      await _insertBook(db, 'A');
      await _insertBook(db, 'B');

      await db.setEpubBookCompleted('A', DateTime.now());
      expect(await db.getCompletedEpubBookKeys(), <String>{'A'});

      // 取消（传 null）清除完成态。
      await db.setEpubBookCompleted('A', null);
      expect(await db.getCompletedEpubBookKeys(), isEmpty);
    });

    test('markEpubBookCompletedIfUnset 幂等：不覆盖既有时间戳', () async {
      final db = await _openDb();
      await _insertBook(db, 'A');
      final DateTime t1 = DateTime.fromMillisecondsSinceEpoch(1000);
      final DateTime t2 = DateTime.fromMillisecondsSinceEpoch(2000);

      // 首次读到末尾 → 写入。
      expect(await db.markEpubBookCompletedIfUnset('A', t1), 1);
      // 再次读到末尾 → 0 行受影响，时间戳不被刷新。
      expect(await db.markEpubBookCompletedIfUnset('A', t2), 0);
      expect((await db.getEpubBook('A'))!.completedAt, t1);
    });

    test('用户取消后再读到末尾 → 重新自动置上（completed_at 为 NULL 才写）', () async {
      final db = await _openDb();
      await _insertBook(db, 'A');
      await db.setEpubBookCompleted('A', DateTime.now());
      await db.setEpubBookCompleted('A', null); // 用户手动取消

      expect(
        await db.markEpubBookCompletedIfUnset(
            'A', DateTime.fromMillisecondsSinceEpoch(5000)),
        1,
        reason: 'completed_at 已被清为 NULL，自动完成应重新写入',
      );
      expect(await db.getCompletedEpubBookKeys(), <String>{'A'});
    });

    test('getCompletedEpubBookKeys 只返回已完成的书', () async {
      final db = await _openDb();
      await _insertBook(db, 'A');
      await _insertBook(db, 'B');
      await _insertBook(db, 'C');
      await db.setEpubBookCompleted('A', DateTime.now());
      await db.setEpubBookCompleted('C', DateTime.now());
      expect(await db.getCompletedEpubBookKeys(), <String>{'A', 'C'});
    });
  });
}
