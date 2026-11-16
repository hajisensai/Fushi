/// 测试用：数 srs.db 的读命令往返（内核读命令 `read` / `read_lib`，packages/fushi_engine/lib/srs/srs_reads.dart）。
///
/// 以前数的是 srs.db 上 Drift 连接的语句往返；Drift 视图删了之后 Dart 对 srs.db 只有两种往返：读命令（这里数）
/// 与内核写命令（`SrsCore.debugCoreCommands`）。
library;

import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:test/test.dart';

/// 统计读命令次数、等待时长与读回的行数。钩子是本 isolate 全局的一个：建出来与每次 [reset] 都把它接到自己身上
/// （同一个测试里有几个计数器时，数的是最近一次 [reset] 之后的读——各测量段先 [reset] 再量），测试结束自动摘钩。
class SrsReadCounter {
  SrsReadCounter() {
    _attach();
    addTearDown(() {
      if (srsDebugReadObserver == _on) srsDebugReadObserver = null;
    });
  }

  void _attach() => srsDebugReadObserver = _on;

  /// 按查询名的次数 / 微秒。
  final Map<String, int> counts = <String, int>{};
  final Map<String, int> micros = <String, int>{};

  /// 读回的总行数。
  int rowsRead = 0;

  /// 单条读命令读回的最多行数（一次物化了多少行到调用方 isolate）。
  int maxRowsPerSelect = 0;

  /// 读回的列式结果总字节数。
  int bytes = 0;

  /// 恒为 0：Dart 对 srs.db 不再开事务（写命令的事务在内核里）。
  int get transactions => 0;

  void _on(String q, int rows, int b, int us) {
    bytes += b;
    counts[q] = (counts[q] ?? 0) + 1;
    micros[q] = (micros[q] ?? 0) + us;
    rowsRead += rows;
    if (rows > maxRowsPerSelect) maxRowsPerSelect = rows;
  }

  void reset() {
    _attach();
    counts.clear();
    micros.clear();
    rowsRead = 0;
    maxRowsPerSelect = 0;
    bytes = 0;
  }

  /// 查询名 [q] 的读命令次数；`select` = 全部读命令（以前数的是 SELECT 语句），别的语句种类恒为 0。
  int count(String q) => q == 'select' ? total : counts[q] ?? 0;

  /// 全部读命令往返。
  int get total => counts.values.fold<int>(0, (int a, int b) => a + b);

  String summary() => <String>[
    for (final MapEntry<String, int> e in counts.entries)
      '${e.key}=${e.value}/${(micros[e.key]! / 1000).round()}ms',
  ].join(' ');
}
