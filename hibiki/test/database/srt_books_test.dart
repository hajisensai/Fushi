import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

SrtBooksCompanion _srtBook({String uid = 'srt/1', String title = 'SRT Book'}) {
  return SrtBooksCompanion.insert(
    uid: uid,
    title: title,
    srtPath: '/tmp/$uid.srt',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  group('SrtBooks table', () {
    test('upsert and retrieve by uid', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook());

      final row = await db.getSrtBookByUid('srt/1');
      expect(row, isNotNull);
      expect(row!.title, 'SRT Book');
    });

    test('getSrtBookByUid returns null for absent uid', () async {
      final db = await _openDb();
      expect(await db.getSrtBookByUid('missing'), isNull);
    });

    test('getAllSrtBooks returns all', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook(uid: 'a'));
      await db.upsertSrtBook(_srtBook(uid: 'b'));

      expect(await db.getAllSrtBooks(), hasLength(2));
    });

    test('deleteSrtBookByUid removes the row and reports 1 deleted', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook());

      // BUG-439: the deleted-row count must surface so batch delete can count
      // only real deletions instead of optimistically assuming success.
      final int removed = await db.deleteSrtBookByUid('srt/1');

      expect(removed, 1);
      expect(await db.getSrtBookByUid('srt/1'), isNull);
    });

    test('deleteSrtBookByUid reports 0 when the uid matched no row (BUG-439)',
        () async {
      final db = await _openDb();

      final int removed = await db.deleteSrtBookByUid('does-not-exist');

      expect(removed, 0);
    });

    // insertOnConflictUpdate resolves on primary key (id), not uid.
    // A second insert with a new auto-increment id hits the UNIQUE(uid)
    // constraint because the original row still occupies that uid slot.
    test('second insert with same uid hits UNIQUE constraint', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook(title: 'V1'));

      expect(
        () => db.upsertSrtBook(_srtBook(title: 'V2')),
        throwsA(isA<SqliteException>()),
      );
    });

    test('delete then re-insert updates by uid', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook(title: 'V1'));

      await db.deleteSrtBookByUid('srt/1');
      await db.upsertSrtBook(_srtBook(title: 'V2'));

      final row = await db.getSrtBookByUid('srt/1');
      expect(row!.title, 'V2');
    });
  });

  // BUG-793：书架有声书列表据此 Drift `.watch()` 流在任意导入路径落库后自动刷新
  // （provider 层再 `.distinct` 按集合去重）。
  group('watchSrtBookUids', () {
    test('emits inserted uid when an audiobook is added', () async {
      final db = await _openDb();
      final emissions = <List<String>>[];
      final sub = db.watchSrtBookUids().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: '初始快照：空库');

      await db.upsertSrtBook(_srtBook(uid: 'srt/new'));
      await pumpEventQueue();
      expect(emissions.last, contains('srt/new'), reason: '插入后集合应含新导入有声书的 uid');
    });

    test('drops removed uid on delete', () async {
      final db = await _openDb();
      await db.upsertSrtBook(_srtBook(uid: 'srt/gone'));
      final emissions = <List<String>>[];
      final sub = db.watchSrtBookUids().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, contains('srt/gone'));

      await db.deleteSrtBookByUid('srt/gone');
      await pumpEventQueue();
      expect(emissions.last, isNot(contains('srt/gone')));
    });
  });
}
