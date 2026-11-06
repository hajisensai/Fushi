// 内存采样探针（[PreviousExitLog.startMemorySampling]）：SRS 原生内核的进程级计数。
//
// 移动端内存耗尽闪退（BUG-4075）要分清「退役的库还驻留没有」「连接 / SQLite 页缓存占多少」，
// 读数来自 native/fushi_fsrs `ffsrs_store_diag_counts`（只取几个计数，不开库、不等长锁）。

import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// `srs=开/存活 sess=… rd=… sqlite=当前/高水位MB`；原生库不可用返回 null。
String? srsMemoryProbe() => SrsCore.diagCounts()?.describe();

/// SRS 重活账本的窗口汇总（[SrsOpLedger.takeSummary]）：上次采样以来哪些内核命令 / srs.db 语句 / 整库装载跑了
/// 几次、用时多少、读回多少，正在跑的长操作，以及修订号 / 页面 provider 的重建次数。窗口里什么都没有返回 null。
String? srsOpLedgerProbe() => SrsOpLedger.takeSummary();
