/// Drift 执行器：语句在 Rust 独占的 srs.db 上执行（docs/specs/2026-10-23-srs-rust-store.md §5）。
///
/// 连接、文件、事务都归 Rust；Drift 只负责把查询构造器拼成 SQL、把结果映射成行类。执行器跑在
/// 后台 isolate（与主库的 `createInBackground` 相同的形态），UI isolate 不做同步 FFI。
///
/// 读写分离（[srsDatabaseConnection]）：
/// - 写那一路：写语句、`runCustom`（含 Drift 用来开关事务的 BEGIN / COMMIT / SAVEPOINT）、事务 / 独占块里的
///   一切语句，在一个后台 isolate 的顺序执行器上、经内核的写连接执行（同事务读得到刚写的未提交行，同一条写连接上
///   的 Rust 命令同样看得见）。Drift 的事务语义（事务开着时事务外的写等它结束）由这条顺序执行器保证。
/// - 读那一路：事务**外**的查询不进上面那条队列，直接发到内核命令 worker 的查询道（`SrsCoreLane.query`），
///   在内核的只读连接池上并发执行（`SrsCore.snapshotQuery`）：同步里几秒的长读跑着时，打开卡片 / 牌组设置的
///   短读不再排在它后面（BUG-3961）。只看已提交的数据——事务开着时它看不到那笔事务未提交的行，与事务外的读
///   本来的语义相同；不是只读查询（PRAGMA 等）改发写那一路。
library;

import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_core_workers.dart';

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

/// [core] 上的 Drift 连接（写那一路在后台 isolate 顺序执行，事务外的查询在内核命令 worker 上并发执行，见库注释）。
/// [core] 必须比返回的连接活得久。
DatabaseConnection srsDatabaseConnection(SrsCore core) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  final DatabaseConnection write = DatabaseConnection.delayed(
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
  return DatabaseConnection(
    SrsSplitExecutor(
      write: write,
      address: address,
      workers: SrsCoreWorkers.of(libraryPath),
    ),
    // 表更新通知与原来同一个 store（写那一路的连接带的）。
    streamQueries: write.streamQueries,
  );
}

/// 一页查询结果：列名 + 行（worker 解码好再送回，可跨 isolate 发送）。
typedef SrsQueryPage = (List<String>, List<List<Object?>>);

/// 在 worker 里跑一条事务外查询；不是只读查询返回 null（调用方改发写那一路）。
/// 顶层函数造闭包：只捕获 [sql] / [args]（见 srs_core_workers.dart「发送」）。
SrsCoreJob<SrsQueryPage?> _snapshotQueryJob(String sql, List<Object?> args) =>
    (SrsCore core) {
      final Uint8List page;
      try {
        page = core.snapshotQuery(sql, args);
      } on SrsCoreException catch (e) {
        if (e.message == kSrsNotSnapshotQuery) return null;
        rethrow;
      }
      final (int _, List<List<Object?>> rows) = srsDecodeRows(page);
      return (rows.first.cast<String>(), rows.sublist(1));
    };

/// 事务外的查询走 [workers] 的查询道并发执行，其余一切（写语句、`runCustom`、批量、事务、独占块）交给 [write]。
///
/// Drift 只在事务 / 独占块之外把语句交给这个执行器的 [runSelect]；块里的语句经 [beginTransaction] /
/// [beginExclusive] 拿到的是 [write] 的子执行器，读己之写不变。
final class SrsSplitExecutor implements QueryExecutor {
  SrsSplitExecutor({
    required QueryExecutor write,
    required int address,
    required SrsCoreWorkers workers,
  }) : _write = write,
       _address = address,
       _workers = workers;

  final QueryExecutor _write;
  final int _address;
  final SrsCoreWorkers _workers;

  /// 在途的事务外查询（[close] 等它们结束再关写那一路，之后装配层才关内核句柄）。
  final Set<Future<void>> _inFlight = <Future<void>>{};
  bool _closed = false;

  @override
  SqlDialect get dialect => _write.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _write.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) {
    if (_closed) {
      return Future<List<Map<String, Object?>>>.error(
        StateError('srs database is closed'),
      );
    }
    final Future<List<Map<String, Object?>>> result = _select(statement, args);
    final Future<void> settled = result.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    _inFlight.add(settled);
    settled.whenComplete(() => _inFlight.remove(settled));
    return result;
  }

  Future<List<Map<String, Object?>>> _select(
    String statement,
    List<Object?> args,
  ) async {
    final SrsQueryPage? page = await _workers.run(
      _address,
      _snapshotQueryJob(statement, args),
      lane: SrsCoreLane.query,
    );
    if (page == null) return _write.runSelect(statement, args);
    final (List<String> names, List<List<Object?>> rows) = page;
    return QueryResult(names, rows).asMap.toList();
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _write.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _write.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _write.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _write.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _write.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _write.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _write.beginExclusive();

  @override
  Future<void> close() async {
    _closed = true;
    await Future.wait(_inFlight.toList());
    await _write.close();
  }
}

/// 同一个 isolate 里直接执行（测试用：省掉起 isolate 的开销，行为相同）。
QueryExecutor srsInlineExecutor(SrsCore core) => DelegatedDatabase(
  SrsRustDelegate(core.address, core.libraryPath),
  isSequential: true,
);
