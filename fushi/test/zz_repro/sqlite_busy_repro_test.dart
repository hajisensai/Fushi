// Throwaway reproduction for the insertPrefIfAbsent SQLITE_BUSY seen on Linux CI.
// Not for merge: lives on a repro/* branch only.
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

const int kReps = int.fromEnvironment('REPS', defaultValue: 300);

Directory _tmp(String p) => Directory.systemTemp.createTempSync(p);

String _describe(Object e) {
  if (e is s3.SqliteException) {
    return 'SqliteException ext=${e.extendedResultCode} '
        'res=${e.resultCode} op=${e.operation} msg=${e.message}';
  }
  final String s = e.toString();
  final RegExp ext = RegExp(r'code (\d+)');
  return '${e.runtimeType} ${ext.firstMatch(s)?.group(0) ?? ''} '
      '${s.length > 300 ? s.substring(0, 300) : s}';
}

class _Tally {
  _Tally(this.name);
  final String name;
  int ok = 0;
  final Map<String, int> errors = <String, int>{};
  final List<int> errorMs = <int>[];
  int maxOkMs = 0;

  void record(Object? error, int ms) {
    if (error == null) {
      ok++;
      if (ms > maxOkMs) maxOkMs = ms;
    } else {
      final String k = _describe(error);
      errors[k] = (errors[k] ?? 0) + 1;
      errorMs.add(ms);
    }
  }

  void report() {
    // ignore: avoid_print
    print(
      'REPRO[$name] ok=$ok maxOkMs=$maxOkMs errors=$errors '
      'errorMs=${errorMs.take(20).toList()}',
    );
  }
}

Future<(Object?, int)> _timed(Future<Object?> Function() f) async {
  final Stopwatch sw = Stopwatch()..start();
  try {
    await f();
    return (null, sw.elapsedMilliseconds);
  } on Object catch (e) {
    return (e, sw.elapsedMilliseconds);
  }
}

void _rawWorker((String, bool) args) {
  final (String path, bool immediate) = args;
  final s3.Database db = s3.sqlite3.open(path);
  db.execute('PRAGMA busy_timeout = 5000');
  db.execute('PRAGMA journal_mode=WAL');
  try {
    db.execute(immediate ? 'BEGIN IMMEDIATE' : 'BEGIN TRANSACTION');
    db.execute(
      'INSERT OR IGNORE INTO preferences (key, value, updated_at) VALUES (?, ?, ?)',
      <Object?>['k', 'v', 1],
    );
    db.execute(
      "INSERT INTO preferences (key, value, updated_at) VALUES ('ver','1',1) "
      'ON CONFLICT(key) DO UPDATE SET value = value + 1',
    );
    db.execute('COMMIT');
  } finally {
    db.close();
  }
}

Future<void> _rawVariant(String name, bool immediate) async {
  final _Tally tally = _Tally(name);
  for (int i = 0; i < kReps; i++) {
    final Directory dir = _tmp('busy_raw_');
    final String path = '${dir.path}/db.sqlite';
    final s3.Database init = s3.sqlite3.open(path);
    init.execute('PRAGMA journal_mode=WAL');
    init.execute(
      'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT, updated_at INT)',
    );
    init.close();
    final List<(Object?, int)> r = await Future.wait(<Future<(Object?, int)>>[
      for (int k = 0; k < 2; k++)
        _timed(() => Isolate.run(() => _rawWorker((path, immediate)))),
    ]);
    for (final (Object?, int) x in r) {
      tally.record(x.$1, x.$2);
    }
    dir.deleteSync(recursive: true);
  }
  tally.report();
}

void main() {
  test('V1 FushiDatabase x2 insertPrefIfAbsent', () async {
    final _Tally tally = _Tally('V1-fushi');
    for (int i = 0; i < kReps; i++) {
      final Directory dir = _tmp('busy_fushi_');
      final FushiDatabase a = FushiDatabase(dir.path);
      final FushiDatabase b = FushiDatabase(dir.path);
      await a.getPref('x');
      await b.getPref('x');
      final List<(Object?, int)> r = await Future.wait(<Future<(Object?, int)>>[
        _timed(() => a.insertPrefIfAbsent('anki_settings', 's:v')),
        _timed(() => b.insertPrefIfAbsent('anki_settings', 's:v')),
      ]);
      for (final (Object?, int) x in r) {
        tally.record(x.$1, x.$2);
      }
      await a.close();
      await b.close();
      dir.deleteSync(recursive: true);
    }
    tally.report();
  }, timeout: const Timeout(Duration(minutes: 20)));

  test(
    'V2 raw sqlite3 deferred BEGIN',
    () => _rawVariant('V2-raw-deferred', false),
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'V3 raw sqlite3 BEGIN IMMEDIATE',
    () => _rawVariant('V3-raw-immediate', true),
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test('V4 drift background x2 transaction', () async {
    final _Tally tally = _Tally('V4-drift');
    for (int i = 0; i < kReps; i++) {
      final Directory dir = _tmp('busy_drift_');
      final File f = File('${dir.path}/db.sqlite');
      final s3.Database init = s3.sqlite3.open(f.path);
      init.execute('PRAGMA journal_mode=WAL');
      init.execute(
        'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT, updated_at INT)',
      );
      init.close();
      void setup(s3.Database db) {
        db.execute('PRAGMA busy_timeout = 5000');
        db.execute('PRAGMA journal_mode=WAL');
      }

      final List<_RawDb> dbs = <_RawDb>[
        for (int k = 0; k < 2; k++)
          _RawDb(NativeDatabase.createInBackground(f, setup: setup)),
      ];
      for (final _RawDb d in dbs) {
        await d.customSelect('SELECT count(*) FROM preferences').get();
      }
      final List<(Object?, int)> r = await Future.wait(<Future<(Object?, int)>>[
        for (final _RawDb d in dbs)
          _timed(
            () => d.transaction<Object?>(() async {
              return d.customUpdate(
                'INSERT OR IGNORE INTO preferences (key, value, updated_at) '
                'VALUES (?, ?, ?)',
                variables: <Variable<Object>>[
                  const Variable<String>('k'),
                  const Variable<String>('v'),
                  const Variable<int>(1),
                ],
              );
            }),
          ),
      ]);
      for (final (Object?, int) x in r) {
        tally.record(x.$1, x.$2);
      }
      for (final _RawDb d in dbs) {
        await d.close();
      }
      dir.deleteSync(recursive: true);
    }
    tally.report();
  }, timeout: const Timeout(Duration(minutes: 20)));
}

class _RawDb extends GeneratedDatabase {
  _RawDb(super.e);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      const <TableInfo<Table, Object?>>[];
  @override
  int get schemaVersion => 1;
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (Migrator m) async {});
}
