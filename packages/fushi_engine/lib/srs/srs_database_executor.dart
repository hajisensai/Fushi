/// Drift 执行器：语句在 Rust 独占的 srs.db 上执行（docs/specs/2026-10-23-srs-rust-store.md §5）。
///
/// 连接、文件、事务都归 Rust；Drift 只负责把查询构造器拼成 SQL、把结果映射成行类。执行器跑在
/// 后台 isolate（与主库的 `createInBackground` 相同的形态），UI isolate 不做同步 FFI。
///
/// 读写分离：写语句、`runCustom`（含 Drift 用来开关事务的 BEGIN / COMMIT / SAVEPOINT）在写连接上；
/// 查询（`runSelect`）在 Drift 事务开着时也在写连接上（同事务读得到刚写的未提交行，同一条写连接上的
/// Rust 命令同样看得见），事务外走内核的读连接快照，不排在 Rust 的长写命令后面。
library;

import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// srs.db 的 schema 归 Rust（store/schema.rs）：Drift 侧版本恒为 1，不做任何迁移。
const int kSrsDriftSchemaVersion = 1;

final class _FixedVersion extends DynamicVersionDelegate {
  const _FixedVersion();

  @override
  Future<int> get schemaVersion async => kSrsDriftSchemaVersion;

  @override
  Future<void> setSchemaVersion(int version) async {}
}

/// [DatabaseDelegate]：每条语句一次 `ffsrs_store_exec`（与 Drift 的 NativeDatabase 每条语句调一次
/// sqlite3 同粒度）；批量语句整批一次 `ffsrs_store_exec_batch`。
final class SrsRustDelegate extends DatabaseDelegate {
  SrsRustDelegate(this._address, this._libraryPath);

  final int _address;
  final String? _libraryPath;
  SrsCore? _core;

  SrsCore get _c => _core ?? (throw StateError('srs delegate not open'));

  @override
  TransactionDelegate get transactionDelegate => const NoTransactionDelegate();

  @override
  DbVersionDelegate get versionDelegate => const _FixedVersion();

  @override
  bool get isOpen => _core != null;

  @override
  Future<void> open(QueryExecutorUser db) async {
    _core = SrsCore.fromAddress(_address, libraryPath: _libraryPath);
  }

  @override
  Future<void> close() async {
    // 句柄归装配层（`SrsCore` 的拥有者）关闭。
    _core = null;
  }

  @override
  Future<QueryResult> runSelect(String statement, List<Object?> args) async {
    final (int _, List<List<Object?>> rows) = srsDecodeRows(
      _c.execQuery(statement, args),
    );
    return QueryResult(rows.first.cast<String>(), rows.sublist(1));
  }

  (int, int) _write(String statement, List<Object?> args) {
    final (int _, List<List<Object?>> rows) = srsDecodeRows(
      _c.exec(statement, args, select: false),
    );
    return (rows.single[0]! as int, rows.single[1]! as int);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      _write(statement, args).$2;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      _write(statement, args).$1;

  @override
  Future<void> runCustom(String statement, List<Object?> args) async {
    // 写连接上、按查询执行：PRAGMA 之类有结果行的语句也能执行（结果丢弃）。事务控制语句必须走这里
    // （内核据此记下 Drift 事务开没开，[runSelect] 的选路靠它），不能走 runSelect 的读连接。
    _c.exec(statement, args, select: true);
  }

  @override
  Future<void> runBatched(BatchedStatements statements) async {
    _c.execBatch(statements.statements, <(int, List<Object?>)>[
      for (final ArgumentsForBatchedStatement a in statements.arguments)
        (a.statementIndex, a.arguments),
    ]);
  }
}

/// [core] 上的 Drift 连接（后台 isolate 执行）。[core] 必须比返回的连接活得久。
DatabaseConnection srsDatabaseConnection(SrsCore core) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  return DatabaseConnection.delayed(
    Future<DatabaseConnection>(() async {
      final DriftIsolate isolate = await DriftIsolate.spawn(
        () => DelegatedDatabase(
          SrsRustDelegate(address, libraryPath),
          isSequential: true,
        ),
      );
      return isolate.connect(singleClientMode: true);
    }),
  );
}

/// 同一个 isolate 里直接执行（测试用：省掉起 isolate 的开销，行为相同）。
QueryExecutor srsInlineExecutor(SrsCore core) => DelegatedDatabase(
  SrsRustDelegate(core.address, core.libraryPath),
  isSequential: true,
);
