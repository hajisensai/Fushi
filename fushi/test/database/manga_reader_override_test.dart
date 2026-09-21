import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> addBook() => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'override-book',
          title: 'Override book',
          epubPath: '/tmp/override-book',
          extractDir: '/tmp/override-book',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: Value(BookFormat.manga.dbValue),
        ),
      );

  test('作品覆盖按 uid LWW 保存、读取和 reset tombstone', () async {
    final String bookKey = await addBook();
    final EpubBookRow book = (await db.getEpubBook(bookKey))!;
    await db.setMangaReaderOverride(book.uid, <String, Object?>{
      'mode': 'longStripGaps',
      'scale': 'fitWidth',
    });
    final MangaReaderOverrideRow first =
        (await db.getMangaReaderOverride(book.uid))!;
    expect(first.deleted, isFalse);
    expect(first.overridesJson, contains('longStripGaps'));

    expect(
      await db.mergeMangaReaderOverride(
        book.uid,
        overrides: <String, Object?>{'mode': 'pagedVertical'},
        updatedAt: first.updatedAt - 1,
        deleted: false,
      ),
      isFalse,
    );
    expect((await db.getMangaReaderOverride(book.uid))!.overridesJson,
        contains('longStripGaps'));

    expect(
      await db.mergeMangaReaderOverride(
        book.uid,
        overrides: const <String, Object?>{},
        updatedAt: first.updatedAt + 10,
        deleted: true,
      ),
      isTrue,
    );
    final MangaReaderOverrideRow reset =
        (await db.getMangaReaderOverride(book.uid))!;
    expect(reset.deleted, isTrue);
    expect(reset.overridesJson, '{}');
  });
}
