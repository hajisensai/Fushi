/// 测试用：数一个 Drift 连接上的语句往返（库在后台 isolate 时每条语句都是一次跨 isolate 往返）。
library;

import 'package:drift/drift.dart';

/// 统计语句往返次数、等待时长与 SELECT 读回的行数。
class CountingInterceptor extends QueryInterceptor {
  final Map<String, int> counts = <String, int>{};
  final Map<String, int> micros = <String, int>{};

  /// SELECT 读回的总行数。
  int rowsRead = 0;

  void reset() {
    counts.clear();
    micros.clear();
    rowsRead = 0;
    transactions = 0;
  }

  int count(String kind) => counts[kind] ?? 0;

  /// 全部语句往返（SELECT / 写 / 批 / 自定义语句）。
  int get total => counts.values.fold<int>(0, (int a, int b) => a + b);

  Future<T> _run<T>(String kind, Future<T> Function() body) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      counts[kind] = (counts[kind] ?? 0) + 1;
      micros[kind] = (micros[kind] ?? 0) + sw.elapsedMicroseconds;
    }
  }

  String summary() => <String>[
    for (final MapEntry<String, int> e in counts.entries)
      '${e.key}=${e.value}/${(micros[e.key]! / 1000).round()}ms',
    'tx=$transactions',
  ].join(' ');

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run('select', () async {
    final List<Map<String, Object?>> rows = await executor.runSelect(
      statement,
      args,
    );
    rowsRead += rows.length;
    return rows;
  });

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run('insert', () => executor.runInsert(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run('update', () => executor.runUpdate(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run('delete', () => executor.runDelete(statement, args));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run('custom', () => executor.runCustom(statement, args));

  /// 开过的事务数（含嵌套事务的保存点）。
  int transactions = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    transactions++;
    return parent.beginTransaction();
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _run('batch', () => executor.runBatched(statements));
}
