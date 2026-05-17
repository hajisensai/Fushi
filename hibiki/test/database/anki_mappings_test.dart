import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('AnkiMappings table', () {
    test('insert and query anki mapping', () async {
      final db = await _openDb();

      await db.into(db.ankiMappings).insert(
            AnkiMappingsCompanion.insert(
              label: 'Default',
              model: 'Basic',
              exportFieldKeysJson: '["term","reading"]',
              creatorFieldKeysJson: '["term","reading"]',
              creatorCollapsedFieldKeysJson: '[]',
              order: 0,
              tagsJson: '["japanese"]',
              enhancementsJson: '{}',
              actionsJson: '{}',
            ),
          );

      final all = await db.select(db.ankiMappings).get();
      expect(all, hasLength(1));
      expect(all.single.label, 'Default');
      expect(all.single.model, 'Basic');
      expect(all.single.exportMediaTags, true);
      expect(all.single.useBrTags, true);
      expect(all.single.prependDictionaryNames, true);
    });

    test('label uniqueness enforced', () async {
      final db = await _openDb();
      final companion = AnkiMappingsCompanion.insert(
        label: 'Unique',
        model: 'Basic',
        exportFieldKeysJson: '[]',
        creatorFieldKeysJson: '[]',
        creatorCollapsedFieldKeysJson: '[]',
        order: 0,
        tagsJson: '[]',
        enhancementsJson: '{}',
        actionsJson: '{}',
      );

      await db.into(db.ankiMappings).insert(companion);

      expect(
        () => db.into(db.ankiMappings).insert(companion),
        throwsA(isA<Exception>()),
      );
    });
  });
}
