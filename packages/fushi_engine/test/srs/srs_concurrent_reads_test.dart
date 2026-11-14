// srs.db 的 Drift 连接：查询并发执行、不排在别的查询后面（BUG-3961，srs_database_executor.dart
// `SrsReadOnlyExecutor`，Rust `store/read_pool.rs`）。用与 app 相同的非内联连接。连接只读：造数走测试专用的原始通道。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 数几千万行的递归 CTE：在内核里跑一两秒，期间不碰任何表。
const String _kLongQuery =
    'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n '
    'WHERE i < 30000000) SELECT SUM(i) AS s FROM n';

void _insert(SrsStorage s, String id) => s.core.debugExecRaw(
  "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (?, 'p', '{}')",
  <Object?>[id],
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
    _insert(storage, 'a');
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

  test('长查询跑着时，内核的写入照常提交，之后发的查询看得见', () async {
    bool longDone = false;
    final Future<void> long = storage.db
        .customSelect(_kLongQuery)
        .getSingle()
        .then((_) => longDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _insert(storage, 'a');
    expect(await _count(storage), 1, reason: 'read after write');
    expect(longDone, isFalse, reason: 'the write waited for the long query');
    await long;
  });

  test('PRAGMA 之类非只读查询不执行（以前回落到写连接）', () async {
    await expectLater(
      storage.db.customSelect('PRAGMA wal_autocheckpoint').get(),
      throwsA(isA<SrsReadOnlyDatabaseError>()),
    );
    await expectLater(
      storage.db.customStatement('PRAGMA wal_autocheckpoint = 0'),
      throwsA(isA<SrsReadOnlyDatabaseError>()),
    );
    expect(
      storage.core.debugSelectRaw('PRAGMA wal_autocheckpoint').single.values,
      isNot(<Object?>[0]),
      reason: 'the PRAGMA reached the write connection',
    );
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
