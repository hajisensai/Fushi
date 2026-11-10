/// 本机写日志的身份与时间（[SrsLogContext]）、参数出处哈希、评分预览的值对象。
///
/// 评分、撤销、手动改期 / 重置、立即重排的结果都由 Rust 内核算（native/fushi_fsrs/src/sync2/sched.rs、
/// store/sync2/sched_local.rs），这里不再有 Dart 的排程副本。
library;

import 'algorithm.dart';
import 'day.dart';
import 'fsrs_engine.dart';
import 'hlc.dart';
import 'ids.dart';
import 'scheduler.dart';

/// 本机写日志所需的身份与时间。
class SrsLogContext {
  SrsLogContext({
    required this.profileUid,
    required this.clock,
    required this.now,
    required this.day,
    String Function(int nowMs)? newId,
  }) : _newId = newId ?? ((int ms) => uuidV7(nowMs: ms));

  final String profileUid;
  final HlcClock clock;

  /// (可信时间毫秒, 时间来源)。
  final (int, SrsTimeSource) Function() now;
  final SrsDayContext day;
  final String Function(int nowMs) _newId;

  String newId(int nowMs) => _newId(nowMs);
}

/// 参数组的出处哈希：算法前缀 + 参数的稳定摘要。
String srsParamsHash(SrsAlgorithm algorithm, List<double> params) {
  if (params.isEmpty) return '${algorithm.wire}:default';
  final String text = params.map((double p) => p.toStringAsFixed(6)).join(',');
  return '${algorithm.wire}:${hash53(text).toRadixString(36)}';
}

/// 评分预览：四个按钮各自的结果，以及算出它们所用的记忆状态。
class SrsAnswerPreview {
  const SrsAnswerPreview({
    required this.plan,
    required this.memoryBefore,
    required this.algorithm,
    required this.params,
    required this.nowMs,
    required this.timeSource,
  });

  final SrsAnswerPlan plan;
  final SrsMemory? memoryBefore;

  /// 这次作答的排程方式，写进日志的 `alg`：宿主上由 RWKV-Instant 排队的 RWKV 牌组是 [SrsAlgorithm.rwkv]
  /// （RWKV 没准备好时它的复习卡根本不出，不存在「RWKV 牌组按 FSRS-7 排」），否则是牌组算法的
  /// [SrsAlgorithm.memoryAlgorithm]——包括没有 RWKV 运行时的宿主（无头服务端 / CLI）上的 RWKV 牌组：那里它按
  /// 存下的 FSRS-7 到期日排队，日志记实际排它的算法。间隔与
  /// 记忆状态一律由记忆算法算（RWKV 牌组是 FSRS-7）：RWKV-Instant 不给间隔，存下的到期日只在导出给 Anki
  /// 时用；统计据日志的 `alg` 区分按 R 排的复习。
  final SrsAlgorithm algorithm;
  final List<double> params;
  final int nowMs;
  final SrsTimeSource timeSource;
}
