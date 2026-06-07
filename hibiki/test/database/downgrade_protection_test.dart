import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// Downgrade protection guard (root-cause fix for the recurring "old app
/// downgrades & destroys the user DB" incidents).
///
/// Constructs an on-disk DB whose user_version (99) is far HIGHER than the
/// code's schemaVersion, with a real table + rows, then opens it via
/// HibikiDatabase. The open MUST be refused with HibikiDatabaseDowngradeException
/// and — crucially — the DB file's tables and rows MUST be left completely
/// intact (no DROP / migrate / rebuild). This locks "downgrade = refuse + data
/// untouched" so the destructive behaviour can never regress.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_downgrade_test');
    dbPath = '${tempDir.path}/hibiki.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Seeds a future-version DB file directly via sqlite3: user_version = 99
  /// (much newer than any code schemaVersion) plus a user table with rows that
  /// stand in for real user data.
  void seedFutureVersionDb() {
    final db = sqlite3.sqlite3.open(dbPath);
    try {
      db.execute('PRAGMA user_version = 99');
      db.execute(
        'CREATE TABLE precious_user_data ('
        'id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
      );
      db.execute(
        'INSERT INTO precious_user_data (id, payload) VALUES '
        "(1, 'novel-progress'), (2, 'anki-cards'), (3, 'reading-stats')",
      );
    } finally {
      db.dispose();
    }
  }

  /// Re-reads the file read-only to assert the seeded table + rows survived.
  void expectSeedDataIntact() {
    final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      final versionRow = db.select('PRAGMA user_version');
      expect(
        versionRow.first.values.first,
        99,
        reason: 'user_version must be left unchanged (no migration ran)',
      );

      final tableRows = db.select(
        'SELECT name FROM sqlite_master '
        "WHERE type = 'table' AND name = 'precious_user_data'",
      );
      expect(
        tableRows,
        isNotEmpty,
        reason: 'the user table must NOT have been dropped',
      );

      final dataRows =
          db.select('SELECT id, payload FROM precious_user_data ORDER BY id');
      expect(dataRows.length, 3, reason: 'all user rows must survive');
      expect(dataRows[0]['payload'], 'novel-progress');
      expect(dataRows[1]['payload'], 'anki-cards');
      expect(dataRows[2]['payload'], 'reading-stats');
    } finally {
      db.dispose();
    }
  }

  test('opening a newer-version DB throws HibikiDatabaseDowngradeException',
      () async {
    seedFutureVersionDb();

    final HibikiDatabase database =
        HibikiDatabase.forTesting(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      try {
        await database.close();
      } catch (_) {
        // The connection failed to open; close may also throw. Ignore.
      }
    });

    // drift opens lazily; the refusal surfaces on the first query.
    await expectLater(
      database.getAllEpubBooks(),
      throwsA(isA<HibikiDatabaseDowngradeException>()),
    );
  });

  test('a refused downgrade leaves the DB file tables and rows intact',
      () async {
    seedFutureVersionDb();

    final HibikiDatabase database =
        HibikiDatabase.forTesting(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      try {
        await database.close();
      } catch (_) {}
    });

    // Trigger the (refused) open.
    await expectLater(
      database.getAllEpubBooks(),
      throwsA(isA<HibikiDatabaseDowngradeException>()),
    );
    // Release the file handle before reopening read-only.
    try {
      await database.close();
    } catch (_) {}

    // The whole point: no DROP / migrate / rebuild touched the file.
    expectSeedDataIntact();
  });

  test('the exception reports both the DB version and the code version',
      () async {
    seedFutureVersionDb();

    final HibikiDatabase database =
        HibikiDatabase.forTesting(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      try {
        await database.close();
      } catch (_) {}
    });

    try {
      await database.getAllEpubBooks();
      fail('expected HibikiDatabaseDowngradeException');
    } on HibikiDatabaseDowngradeException catch (e) {
      expect(e.dbVersion, 99);
      expect(e.appSchemaVersion, database.schemaVersion);
      expect(e.appSchemaVersion, lessThan(e.dbVersion));
    }
  });
}
