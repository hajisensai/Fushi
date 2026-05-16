import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

DictionaryMetadataCompanion _meta({
  String name = 'JMdict',
  String formatKey = 'yomichan',
  int order = 0,
}) {
  return DictionaryMetadataCompanion.insert(
    name: name,
    formatKey: formatKey,
    order: order,
  );
}

void main() {
  group('DictionaryMetadata table', () {
    test('upsert and retrieve all', () async {
      final db = await _openDb();
      await db.upsertDictionaryMeta(_meta());

      final all = await db.getAllDictionaryMetadata();
      expect(all, hasLength(1));
      expect(all.single.name, 'JMdict');
      expect(all.single.formatKey, 'yomichan');
    });

    test('upsert replaces on same primary key', () async {
      final db = await _openDb();
      await db.upsertDictionaryMeta(_meta(order: 0));
      await db.upsertDictionaryMeta(_meta(order: 5));

      final all = await db.getAllDictionaryMetadata();
      expect(all, hasLength(1));
      expect(all.single.order, 5);
    });

    test('deleteDictionaryMeta removes by name', () async {
      final db = await _openDb();
      await db.upsertDictionaryMeta(_meta());

      final count = await db.deleteDictionaryMeta('JMdict');
      expect(count, 1);
      expect(await db.getAllDictionaryMetadata(), isEmpty);
    });

    test('clearAllDictionaryMeta removes everything', () async {
      final db = await _openDb();
      await db.upsertDictionaryMeta(_meta(name: 'A'));
      await db.upsertDictionaryMeta(_meta(name: 'B'));

      await db.clearAllDictionaryMeta();

      expect(await db.getAllDictionaryMetadata(), isEmpty);
    });

    test('default values for type, metadataJson, hidden/collapsed', () async {
      final db = await _openDb();
      await db.upsertDictionaryMeta(_meta());

      final row = (await db.getAllDictionaryMetadata()).single;
      expect(row.type, 'term');
      expect(row.metadataJson, '{}');
      expect(row.hiddenLanguagesJson, '[]');
      expect(row.collapsedLanguagesJson, '[]');
    });
  });

  group('DictionaryHistory table', () {
    test(
        'replaceAllDictionaryHistory inserts and getAllDictionaryHistory reads',
        () async {
      final db = await _openDb();
      await db.replaceAllDictionaryHistory([
        DictionaryHistoryCompanion.insert(
          position: 0,
          resultJson: '{"word":"猫"}',
        ),
        DictionaryHistoryCompanion.insert(
          position: 1,
          resultJson: '{"word":"犬"}',
        ),
      ]);

      final all = await db.getAllDictionaryHistory();
      expect(all, hasLength(2));
    });

    test('replaceAll clears old entries first', () async {
      final db = await _openDb();
      await db.replaceAllDictionaryHistory([
        DictionaryHistoryCompanion.insert(
          position: 0,
          resultJson: '{"word":"old"}',
        ),
      ]);

      await db.replaceAllDictionaryHistory([
        DictionaryHistoryCompanion.insert(
          position: 0,
          resultJson: '{"word":"new"}',
        ),
      ]);

      final all = await db.getAllDictionaryHistory();
      expect(all, hasLength(1));
      expect(all.single.resultJson, '{"word":"new"}');
    });

    test('clearDictionaryHistory removes all entries', () async {
      final db = await _openDb();
      await db.replaceAllDictionaryHistory([
        DictionaryHistoryCompanion.insert(
          position: 0,
          resultJson: '{}',
        ),
      ]);

      await db.clearDictionaryHistory();

      expect(await db.getAllDictionaryHistory(), isEmpty);
    });
  });
}
