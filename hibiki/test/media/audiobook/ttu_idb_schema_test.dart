import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_schema.dart';

void main() {
  group('TtuIdbSchema', () {
    test('opens the books database at the bundled ttu schema version', () {
      expect(TtuIdbSchema.booksDbVersion, 6);
      expect(
        TtuIdbSchema.openBooksDbJs,
        contains("indexedDB.open('books', 6)"),
      );
    });

    test('creates every store required by ttu reading statistics', () {
      expect(TtuIdbSchema.openBooksDbJs, contains('"data"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('keyPath: "id"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"bookmark"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('keyPath: "dataId"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"statistic"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('["title", "dateKey"]'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"lastModified"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"readingGoal"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"audioBook"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"subtitle"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('"handle"'));
    });

    test('repairs the legacy simplified data store during upgrade', () {
      expect(TtuIdbSchema.openBooksDbJs, contains('repairLegacyDataStore'));
      expect(TtuIdbSchema.openBooksDbJs, contains('dataStore.keyPath !== "id"'));
      expect(TtuIdbSchema.openBooksDbJs, contains('db.deleteObjectStore("data")'));
      expect(TtuIdbSchema.openBooksDbJs, contains('record.id'));
    });

    test('repairs legacy section character counts after open', () {
      expect(
        TtuIdbSchema.openBooksDbJs,
        contains('repairLegacySectionCharacters(db)'),
      );
      expect(
        TtuIdbSchema.openBooksDbJs,
        contains('section.characters == null'),
      );
      expect(
        TtuIdbSchema.openBooksDbJs,
        contains('section.charactersWeight'),
      );
    });
  });
}
