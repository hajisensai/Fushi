import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard locking the TODO-905 robust-open invariants into the
/// database.dart open path so a later refactor can't silently regress to the
/// naive "createInBackground + bare PRAGMA journal_mode=WAL, no recovery"
/// version that caused the永远打不开 death loop.
void main() {
  late String src;

  setUpAll(() {
    // Test cwd is hibiki/; the DB lives in the sibling hibiki_core package.
    final File f =
        File('../packages/hibiki_core/lib/src/database/database.dart');
    expect(f.existsSync(), isTrue, reason: 'database.dart must be reachable');
    src = f.readAsStringSync();
  });

  test('open path runs WAL/sidecar recovery, not a bare WAL pragma', () {
    expect(src.contains('_openWithRecovery'), isTrue,
        reason: 'both _openDb and _openDbFile must route through recovery');
    // _openDb / _openDbFile must NOT call createInBackground directly anymore.
    expect(
      RegExp(r'_openDb\b[\s\S]{0,400}createInBackground').hasMatch(src),
      isFalse,
      reason: '_openDb must not bypass recovery with a direct open',
    );
  });

  test('Layer 1 checkpoint runs BEFORE any sidecar deletion (red line #1)', () {
    final int checkpointIdx = src.indexOf('wal_checkpoint(TRUNCATE)');
    final int rebuildIdx = src.indexOf('_rebuildSidecar');
    expect(checkpointIdx, greaterThan(0),
        reason: 'Layer 1 must checkpoint the WAL into the main db');
    expect(rebuildIdx, greaterThan(0),
        reason: 'Layer 2 sidecar rebuild must exist');
    expect(checkpointIdx, lessThan(rebuildIdx),
        reason: 'checkpoint(TRUNCATE) must be defined/run before the sidecar '
            'rebuild so committed WAL frames are never lost (red line #1)');
  });

  test(
      'sidecar rebuild deletes ONLY -wal/-shm, never the main .db (red line #2)',
      () {
    // Isolate the _rebuildSidecar body.
    final int start = src.indexOf('Future<void> _rebuildSidecar');
    expect(start, greaterThan(0));
    final String body = src.substring(start, start + 1400);
    expect(body.contains("File('\$path-wal')"), isTrue,
        reason: 'must target the -wal sidecar');
    expect(body.contains("File('\$path-shm')"), isTrue,
        reason: 'must target the -shm sidecar');
    expect(body.contains('.corrupt-bak-'), isTrue,
        reason: 'must snapshot before deleting (D1)');
    // The deletions must be on the sidecar File handles, NEVER on dbFile.
    expect(RegExp(r'dbFile\s*\.\s*delete').hasMatch(body), isFalse,
        reason: 'the main .db file must NEVER be deleted (red line #2)');
  });

  test('a dedicated unrecoverable exception breaks the retry loop', () {
    expect(src.contains('class HibikiDatabaseUnrecoverableException'), isTrue,
        reason: 'app layer needs a recognisable terminal type so Retry stops '
            'looping (no new infinite loop)');
    expect(src.contains('throw HibikiDatabaseUnrecoverableException'), isTrue);
  });

  test('the :popup process is gated out of sidecar deletion (D3)', () {
    expect(src.contains('allowSidecarDelete'), isTrue,
        reason: 'recovery must gate sidecar deletion per-process');
    expect(src.contains('isMainProcess'), isTrue,
        reason: 'the HibikiDatabase constructor must thread the process role');
  });
}
