import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

// BUG-2335: a parallel migration history already stamped version 97 without
// the upstream v96 column. Version-gated onUpgrade cannot repair this shape.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_same_version_dict_');
    dbPath = '${tempDir.path}${Platform.pathSeparator}fixture.db';
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<int> seed({required bool missingColumn}) async {
    final FushiDatabase fresh = FushiDatabase.atFile(
      dbPath,
      isMainProcess: false,
    );
    try {
      await fresh.customStatement(
        'INSERT INTO dictionary_metadata '
        '(name, format_key, "order", metadata_json, collapsed_languages_json, '
        'expanded_languages_json) VALUES (?, ?, ?, ?, ?, ?)',
        <Object>['fixture', 'yomichan', 3, '{"version":1}', '["ja"]', '["en"]'],
      );
      await fresh.customStatement(
        "ALTER TABLE dictionary_metadata ADD COLUMN legacy_marker TEXT DEFAULT 'keep'",
      );
      return fresh.schemaVersion;
    } finally {
      await fresh.close();
      if (missingColumn) {
        final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
        try {
          raw.execute(
            'ALTER TABLE dictionary_metadata '
            'DROP COLUMN expanded_languages_json',
          );
        } finally {
          raw.dispose();
        }
      }
    }
  }

  Map<String, Object?> snapshot() {
    final sqlite3.Database raw = sqlite3.sqlite3.open(
      dbPath,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      return <String, Object?>{
        'version': raw.select('PRAGMA user_version').single.values.single,
        'schema': raw.select('PRAGMA schema_version').single.values.single,
        'columns': raw
            .select('PRAGMA table_info(dictionary_metadata)')
            .map((sqlite3.Row row) => row['name'])
            .toList(),
        'row': Map<String, Object?>.from(
          raw.select('SELECT * FROM dictionary_metadata').single,
        ),
      };
    } finally {
      raw.dispose();
    }
  }

  test(
    'same-version missing column is repaired before the generated mapper',
    () async {
      final int version = await seed(missingColumn: true);
      final Map<String, Object?> before = snapshot();
      expect(before['version'], version);
      expect(before['columns'], isNot(contains('expanded_languages_json')));
      final FushiDatabase reopened = FushiDatabase.atFile(
        dbPath,
        isMainProcess: false,
      );
      try {
        // This exact generated mapping threw a null-check error at app startup.
        final List<DictionaryMetaRow> rows = await reopened
            .select(reopened.dictionaryMetadata)
            .get();
        expect(rows, hasLength(1));
        expect(rows.single.expandedLanguagesJson, '[]');
        expect(rows.single.collapsedLanguagesJson, '["ja"]');
        expect(rows.single.metadataJson, '{"version":1}');
        expect(rows.single.order, 3);
      } finally {
        await reopened.close();
      }
      final Map<String, Object?> after = snapshot();
      expect(
        after['version'],
        version,
        reason: 'repair must not rewrite user_version',
      );
      final Map<String, Object?> repairedRow = Map<String, Object?>.from(
        after['row']! as Map,
      );
      expect(repairedRow.remove('expanded_languages_json'), '[]');
      expect(
        repairedRow,
        before['row'],
        reason: 'all prior data and extra columns survive',
      );
    },
  );

  test(
    'normal same-version opens preserve explicit expansion and issue no DDL',
    () async {
      await seed(missingColumn: false);
      final Map<String, Object?> before = snapshot();
      for (int attempt = 0; attempt < 2; attempt++) {
        final FushiDatabase reopened = FushiDatabase.atFile(
          dbPath,
          isMainProcess: false,
        );
        try {
          final DictionaryMetaRow row = await reopened
              .select(reopened.dictionaryMetadata)
              .getSingle();
          expect(row.expandedLanguagesJson, '["en"]');
        } finally {
          await reopened.close();
        }
        expect(snapshot(), before);
      }
    },
  );

  test('future-version refusal happens before any structural repair', () async {
    final int version = await seed(missingColumn: true);
    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    raw.execute('PRAGMA user_version = ${version + 1}');
    raw.dispose();
    final Map<String, Object?> before = snapshot();
    final FushiDatabase reopened = FushiDatabase.forTesting(
      NativeDatabase(File(dbPath)),
    );
    try {
      await expectLater(
        reopened.select(reopened.dictionaryMetadata).get(),
        throwsA(isA<FushiDatabaseDowngradeException>()),
      );
    } finally {
      await reopened.close();
    }
    expect(snapshot(), before);
  });
}
