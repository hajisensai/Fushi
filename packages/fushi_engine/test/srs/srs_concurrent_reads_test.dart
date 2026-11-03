// srs.db 的 Drift 连接：事务外的查询并发执行、不排在别的查询 / 写那一路后面（BUG-3961，
// srs_database_executor.dart `SrsSplitExecutor`，Rust `store/read_pool.rs`）。用与 app 相同的非内联连接。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart' show SrsUnknownEventsCompanion;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 数几千万行的递归 CTE：在内核里跑一两秒，期间不碰任何表。
const String _kLongQuery =
    'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n '
    'WHERE i < 30000000) SELECT SUM(i) AS s FROM n';

Future<void> _insert(SrsStorage s, String id) => s.db
    .into(s.db.srsUnknownEvents)
    .insert(
      SrsUnknownEventsCompanion.insert(id: id, profileUid: 'p', json: '{}'),
    );

Future<int> _count(SrsStorage s) async =>
    (await s.db
            .customSelect('SELECT COUNT(*) AS c FROM srs_unknown_events')
            .getSingle())
        .read<int>('c');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late SrsStorage storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('srs_concurrent_reads_');
    storage = await SrsStorage.open(
      path: p.join(dir.path, kSrsDatabaseFileName),
      inline: false,
    );
  });

  tearDown(() async {
    await storage.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 已在用例里断言过关库后可删；这里只是收尾。
    }
  });

  test('长查询跑着时，短查询先返回', () async {
    await _insert(storage, 'a');
    bool longDone = false;
    final Future<void> long = storage.db
        .customSelect(_kLongQuery)
        .getSingle()
        .then((_) => longDone = true);
    // 让长查询先发出去、在内核里跑起来。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final Stopwatch sw = Stopwatch()..start();
    expect(await _count(storage), 1);
    sw.stop();
    expect(
      longDone,
      isFalse,
      reason:
          'short query waited for the long one (${sw.elapsedMilliseconds} ms)',
    );
    await long;
  });

  test('事务里读己之写；同时事务外的查询不等它、只看已提交的', () async {
    await _insert(storage, 'a');
    final Completer<void> inserted = Completer<void>();
    final Completer<void> release = Completer<void>();
    final Future<int> tx = storage.db.transaction(() async {
      await _insert(storage, 'b');
      final int seen = await _count(storage);
      inserted.complete();
      await release.future;
      return seen;
    });
    await inserted.future;
    // 事务还开着：事务外的查询立刻返回，看不到未提交的行。
    expect(
      await _count(storage).timeout(const Duration(seconds: 5)),
      1,
      reason: 'outside query read the open transaction',
    );
    release.complete();
    expect(await tx, 2, reason: 'transaction did not read its own write');
    // 提交之后立刻看得见（写后读）。
    expect(await _count(storage), 2);
  });

  test('写后读、流查询按 readsFrom 失效重跑', () async {
    final Stream<int> counts = storage.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_unknown_events',
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            storage.db.srsUnknownEvents,
          },
        )
        .watch()
        .map((List<QueryRow> r) => r.single.read<int>('c'));
    final List<int> seen = <int>[];
    final Completer<void> first = Completer<void>();
    final Completer<void> second = Completer<void>();
    final StreamSubscription<int> sub = counts.listen((int c) {
      seen.add(c);
      if (!first.isCompleted) {
        first.complete();
      } else if (c == 1 && !second.isCompleted) {
        second.complete();
      }
    });
    await first.future;
    expect(seen, <int>[0]);
    await _insert(storage, 'x');
    expect(await _count(storage), 1, reason: 'read after write');
    await second.future.timeout(const Duration(seconds: 5));
    expect(seen.last, 1);
    await sub.cancel();
  });

  test('PRAGMA 之类非只读查询改走写那一路', () async {
    await storage.db.customStatement('PRAGMA wal_autocheckpoint = 0');
    final int v =
        (await storage.db.customSelect('PRAGMA wal_autocheckpoint').getSingle())
                .data
                .values
                .single
            as int;
    expect(v, 0, reason: 'PRAGMA read a read-only connection');
    await storage.db.customStatement('PRAGMA wal_autocheckpoint = 1000');
  });

  test('关库等在途查询结束，关完不留连接（库文件可删）', () async {
    final Future<QueryRow> long = storage.db
        .customSelect(_kLongQuery)
        .getSingle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await storage.close();
    expect((await long).read<int>('s'), greaterThan(0));
    final File db = File(p.join(dir.path, kSrsDatabaseFileName));
    db.deleteSync();
    expect(db.existsSync(), isFalse);
  });
}
