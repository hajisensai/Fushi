import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../tool/pack/recommended_pack_database.dart';

void main() {
  test(
    'keeps exact dictionary and audio registry rows, clears private content',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await db.upsertDictionaryMeta(
        DictionaryMetadataCompanion.insert(
          name: '日本語シソーラス 類語検索辞典',
          formatKey: 'yomichan',
          order: 20,
        ),
      );
      const Map<String, String> keptPrefs = <String, String>{
        'audio_source_configs': 'j:[{"type":"localAudio","enabled":true}]',
        'local_audio_dbs': 's:[{"path":"/support/local_audio_123.db"}]',
      };
      for (final MapEntry<String, String> pref in keptPrefs.entries) {
        await db.customStatement(
          'INSERT INTO preferences (key, value) VALUES (?, ?)',
          <Object>[pref.key, pref.value],
        );
      }
      for (final String key in <String>[
        'src:reader_fushi:override_title://private-book',
        'sync_google_refresh_token',
        'audio_source_configs_private',
        'local_audio_dbs_backup',
      ]) {
        await db.setPref(key, 'PRIVATE_VALUE');
      }
      await db.customStatement(
        'INSERT INTO clipboard_history (position, content, copied_at) '
        'VALUES (0, ?, 1)',
        <Object>['PRIVATE_CLIPBOARD'],
      );
      final List<Map<String, Object?>> dictionaryBefore =
          (await db.customSelect('SELECT * FROM dictionary_metadata').get())
              .map((row) => row.data)
              .toList();

      await sanitizeRecommendedPackDatabase(db);

      expect(
        (await db.customSelect('SELECT * FROM dictionary_metadata').get())
            .map((row) => row.data)
            .toList(),
        dictionaryBefore,
      );
      final Map<String, String> actualPrefs = <String, String>{
        for (final row
            in await db.customSelect('SELECT * FROM preferences').get())
          row.read<String>('key'): row.read<String>('value'),
      };
      expect(actualPrefs, keptPrefs);
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      for (final row in tables) {
        final String table = row.read<String>('name');
        if (table == 'dictionary_metadata' || table == 'preferences') continue;
        final String quoted = '"${table.replaceAll('"', '""')}"';
        final int count =
            (await db
                    .customSelect('SELECT COUNT(*) AS n FROM $quoted')
                    .getSingle())
                .read<int>('n');
        expect(count, 0, reason: '$table must carry no private rows');
      }
    },
  );

  test(
    'clears future tables with restrictive foreign keys and restores FK mode',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await db.customStatement('PRAGMA foreign_keys = ON');
      await db.customStatement(
        'CREATE TABLE future_private_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, private_text TEXT)',
      );
      await db.customStatement(
        'CREATE TABLE "future private child" '
        '(id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL '
        'REFERENCES future_private_parent(id) ON DELETE RESTRICT)',
      );
      await db.customStatement(
        "INSERT INTO future_private_parent (private_text) VALUES ('PRIVATE')",
      );
      await db.customStatement(
        'INSERT INTO "future private child" VALUES (1, 1)',
      );
      // This is an application table, not a reserved sqlite_ system table.
      await db.customStatement(
        'CREATE TABLE sqliteX_private_payload (private_text TEXT)',
      );
      await db.customStatement(
        "INSERT INTO sqliteX_private_payload VALUES ('PRIVATE')",
      );

      await sanitizeRecommendedPackDatabase(db);

      for (final String table in <String>[
        'future_private_parent',
        'future private child',
        'sqliteX_private_payload',
        'sqlite_sequence',
      ]) {
        expect(
          (await db.customSelect('SELECT * FROM "$table"').get()),
          isEmpty,
          reason: 'future schema data and sequence history must not travel',
        );
      }
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(
        (await db.customSelect('PRAGMA foreign_keys').getSingle()).read<int>(
          'foreign_keys',
        ),
        1,
      );
      await expectLater(
        db.customStatement(
          'INSERT INTO "future private child" VALUES (2, 999)',
        ),
        throwsA(
          predicate<Object>(
            (Object error) =>
                error.toString().contains('FOREIGN KEY constraint failed'),
          ),
        ),
        reason:
            'FK enforcement must still reject orphan writes after sanitizing',
      );
    },
  );

  test(
    'restores an initially disabled foreign-key setting and is repeatable',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await db.customStatement('PRAGMA foreign_keys = OFF');

      await sanitizeRecommendedPackDatabase(db);
      await sanitizeRecommendedPackDatabase(db);

      expect(
        (await db.customSelect('PRAGMA foreign_keys').getSingle()).read<int>(
          'foreign_keys',
        ),
        0,
      );
    },
  );

  test(
    'removes deleted private bytes from the database and WAL on disk',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'recommended_pack_sanitize_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final File databaseFile = File('${directory.path}/fushi.db');
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase(databaseFile),
      );
      bool closed = false;
      addTearDown(() async {
        if (!closed) await db.close();
      });
      await db.customStatement('PRAGMA journal_mode = WAL');
      await db.customStatement('PRAGMA secure_delete = OFF');
      await db.customStatement(
        'CREATE TABLE future_private_payload '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT)',
      );
      const String sentinel = 'RECOMMENDED_PACK_PRIVATE_SENTINEL_71638';
      final String payload = List<String>.filled(256, sentinel).join('|');
      await db.customStatement(
        'INSERT INTO future_private_payload (payload) VALUES (?)',
        <Object>[payload],
      );
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      expect(
        latin1.decode(await databaseFile.readAsBytes()).contains(sentinel),
        isTrue,
        reason: 'prove the private marker actually reached database pages',
      );

      await sanitizeRecommendedPackDatabase(db);
      await db.close();
      closed = true;

      for (final FileSystemEntity entity in directory.listSync()) {
        if (entity is! File) continue;
        expect(
          latin1.decode(await entity.readAsBytes()).contains(sentinel),
          isFalse,
          reason: '${entity.path} must not retain recoverable private bytes',
        );
      }
    },
  );
}
