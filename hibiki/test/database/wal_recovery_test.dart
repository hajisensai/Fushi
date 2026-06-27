import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// TODO-905 — robust WAL/sidecar open + recovery.
///
/// Reproduces the "hard-killed → DB永远打不开" symptom with REAL on-disk files
/// (a `NativeDatabase.memory()` has no real `-wal`/`-shm`, so it cannot trigger
/// the sidecar open error at all). A healthy `hibiki.db` is seeded with rows,
/// then a poisoned sidecar is planted so the normal WAL open path fails. The
/// recovery ladder must:
///   - Layer 1/2: open succeeds anyway and ALL seeded rows survive (the
///     checkpoint flushes WAL frames into the main db before the sidecar is
///     rebuilt — no data loss);
///   - never delete the main `hibiki.db` (red line);
///   - take a `.corrupt-bak` snapshot before deleting any sidecar;
/// and when the MAIN db itself is corrupt, open must throw the dedicated
/// [HibikiDatabaseUnrecoverableException] (so the app stops the Retry loop
/// instead of looping forever — the very TODO-905 bug).
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_wal_recovery_test');
    dbPath = '${tempDir.path}/hibiki.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // A connection may still hold the file briefly on Windows; ignore.
      }
    }
  });

  /// Seeds a real, healthy WAL-mode DB carrying user data, then closes it so the
  /// sidecars are checkpointed away cleanly. The migration ladder runs on first
  /// open below; here we only need a valid file with at least one user row, so
  /// we write a row into a table the schema owns (epub_books via raw SQL is
  /// brittle across migrations — instead drive it through HibikiDatabase once).
  Future<void> seedHealthyDb() async {
    final HibikiDatabase db = HibikiDatabase(tempDir.path);
    await db.setPref('todo905_marker', 'survived');
    await db.close();
  }

  /// Plants a poisoned `-wal` sidecar (a DIRECTORY where SQLite expects a file)
  /// so the normal `PRAGMA journal_mode=WAL` open path fails with a
  /// sidecar-class error — the deterministic, cross-platform stand-in for the
  /// Windows mmap-lock residue that produced SqliteException(1546) in the wild.
  void poisonWalSidecar() {
    final Directory walDir = Directory('$dbPath-wal');
    walDir.createSync();
  }

  test(
      'a poisoned -wal sidecar is recovered; open succeeds and seeded data '
      'survives (Layer 1/2, no data loss)', () async {
    await seedHealthyDb();
    poisonWalSidecar();

    // Sanity: the raw open path really does fail before recovery (this is the
    // pre-fix 永远打不开 failure mode).
    Object? rawError;
    try {
      final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
      raw.execute('PRAGMA journal_mode=WAL');
      raw.dispose();
    } catch (e) {
      rawError = e;
    }
    expect(rawError, isNotNull,
        reason: 'the poisoned sidecar must break the naive WAL open');

    // The robust open must recover and return all seeded data intact.
    final HibikiDatabase db = HibikiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });
    final String? marker = await db.getPref('todo905_marker');
    expect(marker, 'survived',
        reason: 'recovery must preserve committed data (checkpoint then '
            'rebuild — never a fresh empty db)');
  });

  test('recovery NEVER deletes the main hibiki.db and snapshots before delete',
      () async {
    await seedHealthyDb();
    final int mainSizeBefore = File(dbPath).lengthSync();
    poisonWalSidecar();

    final HibikiDatabase db = HibikiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });
    // Force the open + recovery.
    await db.getPref('todo905_marker');

    // Red line: the main db file must still exist (never deleted).
    expect(File(dbPath).existsSync(), isTrue,
        reason: 'recovery must NEVER delete the main hibiki.db');
    // Its content survived (size did not collapse to an empty rebuild).
    expect(File(dbPath).lengthSync(), greaterThanOrEqualTo(mainSizeBefore),
        reason: 'main db kept its pages (checkpoint folded WAL in, no wipe)');

    // A .corrupt-bak snapshot was taken before any sidecar deletion (D1).
    final bool snapshotted = tempDir
        .listSync()
        .whereType<File>()
        .any((File f) => f.path.contains('.corrupt-bak-'));
    expect(snapshotted, isTrue,
        reason: 'a .corrupt-bak snapshot must be written before deleting a '
            'sidecar (data-safety fallback)');
  });

  test('a corrupt MAIN db throws HibikiDatabaseUnrecoverableException',
      () async {
    // Write garbage as the main db file (not a valid SQLite header).
    File(dbPath).writeAsBytesSync(
        List<int>.generate(4096, (int i) => (i * 31 + 7) & 0xFF));

    final HibikiDatabase db = HibikiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    await expectLater(
      db.getPref('anything'),
      throwsA(isA<HibikiDatabaseUnrecoverableException>()),
      reason: 'a corrupt main db must surface a dedicated terminal type so the '
          'app stops the Retry loop instead of looping forever',
    );
  });

  test(
      'the :popup process (isMainProcess: false) backs off instead of '
      'deleting a sidecar it does not own (D3)', () async {
    await seedHealthyDb();
    poisonWalSidecar();

    // The popup process must NOT delete the sidecar; it backs off with the
    // terminal exception so the main process owns recovery. (A directory -wal
    // cannot be checkpointed away by Layer 1, so Layer 2 is reached, where the
    // non-main process refuses.)
    final HibikiDatabase popupDb =
        HibikiDatabase(tempDir.path, isMainProcess: false);
    addTearDown(() async {
      try {
        await popupDb.close();
      } catch (_) {}
    });

    await expectLater(
      popupDb.getPref('anything'),
      throwsA(isA<HibikiDatabaseUnrecoverableException>()),
      reason: 'non-main process must back off on a sidecar error, not delete',
    );
    // It must NOT have deleted the poisoned -wal (the main process owns that).
    expect(Directory('$dbPath-wal').existsSync(), isTrue,
        reason: ':popup must not delete a sidecar it does not own');
  });
}
