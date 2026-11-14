/// Drift 执行器：**只读**查询在 Rust 独占的 srs.db 上执行（docs/specs/2026-10-23-srs-rust-store.md §5）。
///
/// 连接、文件、事务都归 Rust；Drift 只负责把查询构造器拼成 SQL、把结果映射成行类。srs.db 的每一笔写入都是内核
/// 命令（`SrsCore.sync2` 等，一次持写锁、一个 SAVEPOINT）：这里的写入口——写语句、`runCustom`、批量、事务、
/// 独占块——一律抛 [SrsReadOnlyDatabaseError]，不到内核；内核那一侧的执行器入口同样只读（`store::READ_ONLY`）。
/// 以前写语句与 Drift 事务经一个后台 isolate 上的顺序执行器落在内核的写连接上，Rust 命令嵌在 Drift 开的事务里；
/// 写路径全部收进内核之后那条路没有调用方，连同「Drift 事务开没开」的状态一起删了。
///
/// 查询（[srsDatabaseConnection]）：直接发到内核命令 worker 的查询道（`SrsCoreLane.query`，worker 数 = 内核只读
/// 连接池的上限 `SrsCore.readConcurrency`，空闲一分钟多起的 worker 收掉），在内核的只读连接池上并发执行
/// （`SrsCore.snapshotQuery`）：同步里几秒的长读跑着时，打开卡片 / 牌组设置的短读不排在它后面（BUG-3961）。UI
/// isolate 不做同步 FFI。只看已提交的数据；内核写命令在返回前提交完，所以等到写命令返回后再发的查询一定看得见它。
library;

import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/drift.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';

/// srs.db 的 schema 归 Rust（store/schema.rs）：Drift 侧版本恒为 1，不做任何迁移。
const int kSrsDriftSchemaVersion = 1;

/// 经 Drift 写 srs.db（写语句、PRAGMA、事务、批量）：srs.db 经 Drift 只读，写入一律是内核命令。消息以
/// [kSrsReadOnlyExecutor] 开头（与内核执行器入口的报错相同）。
final class SrsReadOnlyDatabaseError extends UnsupportedError {
  SrsReadOnlyDatabaseError(String what) : super('$kSrsReadOnlyExecutor: $what');
}

/// 两个只读执行器共用的那一半：没有要打开的东西，写入口——写语句、`runCustom`、批量、事务、独占块——一律抛
/// [SrsReadOnlyDatabaseError]，不到内核。事务在 [beginTransaction] 就拒绝，不让 Drift 的事务机器起步：Drift 自带的
/// 语句式事务（`DelegatedDatabase` + `NoTransactionDelegate`）要等发 `BEGIN` 才知道被拒，它随后的回滚路径会把只读
/// 错误盖成自己内部的 `StateError`（Future already completed）。
abstract base class _SrsReadOnlyBase implements QueryExecutor {
  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  /// 没有要打开的东西：连接归内核（装配层已开好 [SrsCore]），Drift 侧没有迁移、没有打开时要跑的语句
  /// （schema 归 Rust，Drift 侧版本恒为 [kSrsDriftSchemaVersion]）。
  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => true;

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      Future<int>.error(SrsReadOnlyDatabaseError(statement));

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      Future<int>.error(SrsReadOnlyDatabaseError(statement));

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      Future<int>.error(SrsReadOnlyDatabaseError(statement));

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      Future<void>.error(SrsReadOnlyDatabaseError(statement));

  @override
  Future<void> runBatched(BatchedStatements statements) => Future<void>.error(
    SrsReadOnlyDatabaseError(
      'batch of ${statements.arguments.length} statements',
    ),
  );

  @override
  TransactionExecutor beginTransaction() =>
      throw SrsReadOnlyDatabaseError('transaction');

  @override
  QueryExecutor beginExclusive() =>
      throw SrsReadOnlyDatabaseError('exclusive block');
}

/// 同 isolate 的只读执行器（[srsInlineExecutor]；测试与没有 worker 池的宿主用，省掉起 isolate 的开销）：每条查询
/// 一次同步的 `ffsrs_store_exec`，在内核专用的一条只读连接上跑（`SrsCore.execQuery`）。
final class SrsInlineExecutor extends _SrsReadOnlyBase {
  SrsInlineExecutor(SrsCore core)
    : _address = core.address,
      _libraryPath = core.libraryPath;

  final int _address;
  final String? _libraryPath;
  SrsCore? _core;
  bool _closed = false;

  /// 经执行器送进内核的查询数（写路径往返数的验收用：写操作发出的 Drift 读）。按 isolate 计。
  @visibleForTesting
  static int debugStatements = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async {
    if (_closed) throw StateError('srs database is closed');
    debugStatements++;
    final SrsCore core = _core ??= SrsCore.fromAddress(
      _address,
      libraryPath: _libraryPath,
    );
    final Uint8List page;
    try {
      page = core.execQuery(statement, args);
    } on SrsCoreException catch (e) {
      // 不是只读查询（PRAGMA、`… RETURNING`）：与写入口同一个错误类型。
      if (e.message.startsWith(kSrsReadOnlyExecutor)) {
        throw SrsReadOnlyDatabaseError(statement);
      }
      rethrow;
    }
    final (int _, List<List<Object?>> rows) = srsDecodeRows(page);
    return QueryResult(
      rows.first.cast<String>(),
      rows.sublist(1),
    ).asMap.toList();
  }

  /// 句柄归装配层（`SrsCore` 的拥有者）关闭。
  @override
  Future<void> close() async {
    _closed = true;
    _core = null;
  }
}

/// [core] 上的 Drift 连接（查询在内核命令 worker 上并发执行，写入口只读，见库注释）。[core] 必须比返回的连接
/// 活得久。
DatabaseConnection srsDatabaseConnection(SrsCore core) {
  // 查询道的 worker 上限 = 内核只读连接池的上限（按核数算，只在 Rust 里算一次；这一下只读一个数，不碰库）。
  final SrsCoreWorkers workers = SrsCoreWorkers.of(core.libraryPath)
    ..setQueryConcurrency(core.readConcurrency);
  return DatabaseConnection(
    SrsReadOnlyExecutor(address: core.address, workers: workers),
  );
}

/// 一页查询结果：列名 + 行（worker 解码好再送回，可跨 isolate 发送）。
typedef SrsQueryPage = (List<String>, List<List<Object?>>);

/// 在 worker 里跑一条查询；不是只读查询返回 null（调用方报只读错误）。
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

/// 只读的 Drift 执行器：查询走 [workers] 的查询道并发执行；写入口（写语句、`runCustom`、批量、事务、独占块）一律
/// 抛 [SrsReadOnlyDatabaseError]。不执行任何打开语句（schema 归 Rust，Drift 侧没有迁移）。
final class SrsReadOnlyExecutor extends _SrsReadOnlyBase {
  SrsReadOnlyExecutor({required int address, required SrsCoreWorkers workers})
    : _address = address,
      _workers = workers;

  final int _address;
  final SrsCoreWorkers _workers;

  /// 在 worker 上在途的查询数（[close] 等它归零，之后装配层才关内核句柄）。
  ///
  /// 只在根 zone 里维护：提交时同步加一，worker 回执到了在池子的根 zone 回调里（[SrsCoreWorkers.run] 的
  /// `onSettled`）同步减一。不能挂在调用方 zone 的 Future 上——调用方的 zone 可能再也不跑微任务（widget 测试里
  /// 页面在 FakeAsync zone 发的流查询），那样 [close] 永远等不到（PR 2771 审查：unit-tests 分片挂满 60 分钟）。
  int _inFlight = 0;

  /// [close] 在等在途查询归零时建的 Completer（建在根 zone：完成时的微任务进根队列，真实事件循环与
  /// `runAsync` 都冲刷得到）。
  Completer<void>? _drained;
  bool _closed = false;

  /// 测试：worker 上在途的查询数。
  @visibleForTesting
  int get debugInFlight => _inFlight;

  void _settled() {
    _inFlight--;
    if (_inFlight == 0) _drained?.complete();
  }

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
    // 同步登记、同步提交：计数只覆盖 worker 那一段（结束时由池子在根 zone 里减）。
    _inFlight++;
    final int token = SrsOpLedger.begin(srsSqlLedgerName(statement));
    final Future<SrsQueryPage?> page = _workers.run(
      _address,
      _snapshotQueryJob(statement, args),
      lane: SrsCoreLane.query,
      onSettled: _settled,
    );
    return _select(page, statement, token);
  }

  Future<List<Map<String, Object?>>> _select(
    Future<SrsQueryPage?> pending,
    String statement,
    int ledgerToken,
  ) async {
    final SrsQueryPage? page;
    try {
      page = await pending;
    } on Object {
      SrsOpLedger.end(ledgerToken);
      rethrow;
    }
    if (page == null) {
      // 不是只读查询（PRAGMA、`… RETURNING`）：内核没有执行。
      SrsOpLedger.cancel(ledgerToken);
      throw SrsReadOnlyDatabaseError(statement);
    }
    final (List<String> names, List<List<Object?>> rows) = page;
    final List<Map<String, Object?>> out = QueryResult(
      names,
      rows,
    ).asMap.toList();
    SrsOpLedger.end(
      ledgerToken,
      bytes: srsRowsLedgerBytes(out),
      rows: out.length,
    );
    return out;
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (_inFlight > 0) {
      final Completer<void> drained = _drained ??= Zone.root
          .run<Completer<void>>(() => Completer<void>());
      await drained.future;
    }
  }
}

/// 同一个 isolate 里直接执行查询（测试与没有 worker 池的宿主用：省掉起 isolate 的开销）。同样只读。
QueryExecutor srsInlineExecutor(SrsCore core) => SrsInlineExecutor(core);

/// 一批查询结果读回的数据量（账本用）：字符串按 UTF-16 码元数、BLOB 按字节。
int srsRowsLedgerBytes(List<Map<String, Object?>> rows) {
  int bytes = 0;
  for (final Map<String, Object?> r in rows) {
    for (final Object? v in r.values) {
      if (v is String) {
        bytes += v.length;
      } else if (v is Uint8List) {
        bytes += v.length;
      }
    }
  }
  return bytes;
}
