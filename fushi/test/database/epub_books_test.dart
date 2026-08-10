import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

EpubBooksCompanion _book({
  String title = 'Test Book',
}) {
  return EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/tmp/$title.epub',
    extractDir: '/tmp/$title',
    chapterCount: 3,
    chaptersJson: '["ch1","ch2","ch3"]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  group('EpubBooks table', () {
    test('insertEpubBook returns the bookKey', () async {
      final db = await _openDb();

      final key = await db.insertEpubBook(_book(title: 'My Novel'));

      expect(key, 'My Novel');
    });

    test('getEpubBook retrieves by bookKey', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book(title: 'My Novel'));

      final row = await db.getEpubBook(key);

      expect(row, isNotNull);
      expect(row!.title, 'My Novel');
      expect(row.chapterCount, 3);
    });

    test('getEpubBook returns null for absent key', () async {
      final db = await _openDb();

      expect(await db.getEpubBook('nope'), isNull);
    });

    test('getAllEpubBooks returns all inserted books', () async {
      final db = await _openDb();
      await db.insertEpubBook(_book(title: 'A'));
      await db.insertEpubBook(_book(title: 'B'));

      final all = await db.getAllEpubBooks();

      expect(all, hasLength(2));
    });

    test('updateEpubBookPath changes the epub path', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book());

      await db.updateEpubBookPath(key, '/new/path.epub');

      final row = await db.getEpubBook(key);
      expect(row!.epubPath, '/new/path.epub');
    });

    test('deleteEpubBook removes the row', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book());

      final deleted = await db.deleteEpubBook(key);

      expect(deleted, 1);
      expect(await db.getEpubBook(key), isNull);
    });
  });

  // BUG-793：书架据此 Drift `.watch()` 流在任意导入路径落库后自动刷新（provider
  // 层再 `.distinct` 按集合去重，纯列更新不触发重算）。
  group('watchEpubBookKeys', () {
    test('emits inserted bookKey when a book is added', () async {
      final db = await _openDb();
      final emissions = <List<String>>[];
      final sub = db.watchEpubBookKeys().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: '初始快照：空库');

      await db.insertEpubBook(_book(title: 'My Novel'));
      await pumpEventQueue();
      expect(emissions.last, contains('My Novel'),
          reason: '插入后集合应含新导入书的 bookKey（书架据此刷新）');
    });

    test('drops removed bookKey on delete', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book(title: 'Doomed'));
      final emissions = <List<String>>[];
      final sub = db.watchEpubBookKeys().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, contains('Doomed'));

      await db.deleteEpubBook(key);
      await pumpEventQueue();
      expect(emissions.last, isNot(contains('Doomed')));
    });

    test('key set unchanged on column-only update (dedup source)', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book(title: 'Stable'));
      final emissions = <List<String>>[];
      final sub = db.watchEpubBookKeys().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      // 纯列更新（改路径）：即便 Drift 表级失效再发流，key 集合仍是 {Stable}，
      // provider 的 `.distinct` 据此去重、不重算书架。
      await db.updateEpubBookPath(key, '/moved/stable.epub');
      await pumpEventQueue();
      expect(
        emissions
            .every((List<String> e) => e.length == 1 && e.first == 'Stable'),
        isTrue,
        reason: '改路径不改变 bookKey 集合',
      );
    });
  });

  group('v81 本机稳定 uid（P3 Stage 1 身份地基）', () {
    test('insertEpubBook 未携带 uid 时单点自动生成，且互不重复', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertEpubBook(_book(title: 'A'));
      await db.insertEpubBook(_book(title: 'B'));

      final rows = await db.getAllEpubBooks();
      final uids = rows.map((r) => r.uid).toSet();
      expect(uids.length, 2, reason: '自动生成且唯一');
      expect(uids.every((u) => u.startsWith('book_')), isTrue);
      expect(await db.getEpubBookByUid(rows.first.uid), isNotNull,
          reason: '按 uid 读取口可用');
    });

    test('携带 uid 时尊重调用方（迁移/恢复路径要保留既有身份）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertEpubBook(
          _book(title: 'A').copyWith(uid: const Value('book_fixed_1')));
      expect((await db.getAllEpubBooks()).single.uid, 'book_fixed_1');
    });

    test('fresh 库 uid 唯一索引在场（onCreate 内联，与 v81 迁移步成对）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final idx = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
              "AND name='idx_epub_books_uid'")
          .get();
      expect(idx, hasLength(1));
    });
  });
}
