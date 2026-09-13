import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// `getEpubBookMetas()`：`epub_books` 的瘦投影，供只要 title / uid / importedAt /
/// format 的调用方（书架映射、统计事实面、导入重复检查、远端去重）用，不再把
/// 每本几十 KB 的 `chaptersJson` / `tocJson` 整库拉出来。
///
/// 守两点：① 字段与全行读取逐列一致、顺序同 `getAllEpubBooks`（importedAt 降序）；
/// ② `getPrefsByPrefix` 前缀查询把 `_` / `%` 按字面转义（偏好键里全是下划线，
/// 不转义就成了单字符通配）。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

EpubBooksCompanion _book({
  required String title,
  required int importedAt,
  String format = 'epub',
}) {
  return EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/tmp/$title.epub',
    extractDir: '/tmp/$title',
    chapterCount: 3,
    chaptersJson: '[{"characters": 1000}, {"characters": 2000}]',
    tocJson: const Value('[{"title": "big toc"}]'),
    importedAt: importedAt,
    format: Value(format),
  );
}

void main() {
  group('getEpubBookMetas', () {
    test('projects the same identity columns as the full row, same order',
        () async {
      final FushiDatabase db = await _openDb();
      await db.insertEpubBook(_book(title: 'Old', importedAt: 100));
      await db.insertEpubBook(
          _book(title: 'Comic', importedAt: 300, format: 'manga'));
      await db.insertEpubBook(_book(title: 'New', importedAt: 200));
      await db.setEpubBookCompleted(
          'Old', DateTime.fromMillisecondsSinceEpoch(5000));

      final List<EpubBookRow> full = await db.getAllEpubBooks();
      final List<EpubBookMeta> metas = await db.getEpubBookMetas();

      expect(metas.map((EpubBookMeta m) => m.bookKey).toList(),
          full.map((EpubBookRow r) => r.bookKey).toList(),
          reason: '与 getAllEpubBooks 同序（importedAt 降序）');
      expect(metas.map((EpubBookMeta m) => m.bookKey).toList(),
          <String>['Comic', 'New', 'Old']);
      for (int i = 0; i < full.length; i++) {
        final EpubBookRow r = full[i];
        final EpubBookMeta m = metas[i];
        expect(m.uid, r.uid);
        expect(m.title, r.title);
        expect(m.format, r.format);
        expect(m.importedAt, r.importedAt);
        expect(m.extractDir, r.extractDir);
        expect(m.completedAt, r.completedAt);
      }
      expect(metas.last.completedAt, isNotNull);
      expect(metas.first.format, 'manga');
    });

    test('empty library yields empty list', () async {
      final FushiDatabase db = await _openDb();
      expect(await db.getEpubBookMetas(), isEmpty);
    });
  });

  group('getPrefsByPrefix', () {
    test('returns only keys under the prefix, literal underscore', () async {
      final FushiDatabase db = await _openDb();
      await db.setPref('audiobook_health_overlay_A', 'a');
      await db.setPref('audiobook_health_overlay_B', 'b');
      // `_` 若被当通配符，这条会被 'audiobook_health_overlay_' 误命中。
      await db.setPref('audiobookXhealthXoverlayXC', 'c');
      await db.setPref('other', 'o');

      final Map<String, String> got =
          await db.getPrefsByPrefix('audiobook_health_overlay_');

      expect(got, <String, String>{
        'audiobook_health_overlay_A': 'a',
        'audiobook_health_overlay_B': 'b',
      });
    });

    test('percent in prefix is literal too', () async {
      final FushiDatabase db = await _openDb();
      await db.setPref('p%q_1', 'x');
      await db.setPref('pZq_1', 'y');
      expect(await db.getPrefsByPrefix('p%q'), <String, String>{'p%q_1': 'x'});
    });
  });
}
