/// srs.db 的只读查询：内核读命令 `read`（一个 profile 的数据）与 `read_lib`（不针对单个 profile），
/// native/fushi_fsrs/src/store/reads.rs。
///
/// srs.db 的表结构、SQL、索引选择与 ID 列编码只在内核里：Dart 只发「查询名 + 参数」，拿回按列编码的结果
/// （[SrsColumns]）。以前这些读经 srs.db 上的 Drift 视图，Dart 拼 SQL 文本交给内核的执行器，表结构因此有两处在写。
///
/// - 在内核命令 worker 的查询道（[SrsCoreLane.query]）上跑：内核在它的只读连接池上并发执行（一条命令一个读事务），
///   不排写锁，同步里几秒的长读跑着时短读不排在它后面（BUG-3961）。UI isolate 不做同步 FFI。
/// - 只看已提交的数据；内核写命令在返回前提交完，所以写命令返回后再发的读一定看得见它。
/// - `read` 的每条查询都带本 profile 的归属条件：别的 profile 名下的 ID 读出来就是「不存在」。
library;

import 'dart:isolate' show TransferableTypedData;
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';

/// 一次读命令的结果：回包 JSON（只有一两个数的查询直接放在这里）+ 列式表（单表查询的表名是 `t`）。
final class SrsReadResult {
  const SrsReadResult(this.json, this.tables);

  final Map<String, Object?> json;
  final Map<String, SrsColumns> tables;

  /// 单表查询的那张表。
  SrsColumns get table => tables['t']!;
}

/// 经读命令发出的查询数（测试核对一次操作的读往返数）。按 isolate 计。
@visibleForTesting
int srsDebugReadCommands = 0;

/// 测试钩子：每条读命令返回后调一次（查询名、读回的行数、列式结果的字节数、往返微秒数）。按 isolate。
@visibleForTesting
void Function(String q, int rows, int bytes, int micros)? srsDebugReadObserver;

/// [profile] 的一条只读查询 [q]（参数 [args]，键见 store/reads.rs 各函数的文档）。
Future<SrsReadResult> srsRead(
  SrsCore core,
  String profile,
  String q, [
  Map<String, Object?> args = const <String, Object?>{},
]) => _run(core, <String, Object?>{
  ...args,
  'op': 'read',
  'q': q,
  'profile': profile,
});

/// 不针对单个 profile 的只读查询 [q]（`read_lib`）。
Future<SrsReadResult> srsReadLib(
  SrsCore core,
  String q, [
  Map<String, Object?> args = const <String, Object?>{},
]) => _run(core, <String, Object?>{...args, 'op': 'read_lib', 'q': q});

Future<SrsReadResult> _run(SrsCore core, Map<String, Object?> request) async {
  srsDebugReadCommands++;
  final int token = SrsOpLedger.begin('core:${request['op']}:${request['q']}');
  final Stopwatch sw = Stopwatch()..start();
  int bytes = 0;
  int rows = 0;
  try {
    final (
      Object? json,
      Map<String, TransferableTypedData> files,
    ) = await SrsCoreWorkers.of(
      core.libraryPath,
    ).run(core.address, _readJob(request), lane: SrsCoreLane.query);
    final Map<String, SrsColumns> tables = <String, SrsColumns>{};
    for (final MapEntry<String, TransferableTypedData> f in files.entries) {
      final Uint8List b = f.value.materialize().asUint8List();
      bytes += b.length;
      final SrsColumns c = SrsColumns.decode(b);
      rows += c.rows;
      tables[f.key] = c;
    }
    return SrsReadResult(
      json is Map ? json.cast<String, Object?>() : const <String, Object?>{},
      tables,
    );
  } finally {
    SrsOpLedger.end(token, bytes: bytes, rows: rows);
    srsDebugReadObserver?.call(
      request['q']! as String,
      rows,
      bytes,
      sw.elapsedMicroseconds,
    );
  }
}

/// 在 worker 里跑一条读命令。顶层函数造闭包：只捕获 [request]（见 srs_core_workers.dart「发送」）。
SrsCoreJob<(Object?, Map<String, TransferableTypedData>)> _readJob(
  Map<String, Object?> request,
) => (SrsCore c) {
  final SrsSync2Result r = c.sync2(request);
  return (
    r.json,
    <String, TransferableTypedData>{
      for (final (String name, Uint8List bytes) in r.files)
        name: TransferableTypedData.fromList(<TypedData>[bytes]),
    },
  );
};
