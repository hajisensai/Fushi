import 'package:fushi/src/sync/sync_utils.dart';

/// 同步状态（聚合统计 / 收藏、合集清单）**本地落库步骤**的 app 级窄互斥
/// （BUG-2717）。
///
/// 两类写者共用它：
/// - 本机作为互联 host 时，对端 PUT 聚合快照 / POST 合集清单的处理
///   （`LocalLibraryHostService` 的 `runSyncStateExclusive`）；
/// - 本机自己的出站同步（云 / 互联 client）把合并结果写回本地的那一步
///   （`AggregateSyncService.localApplyLock`、`SyncOrchestrator` 的合集落库段）。
///
/// 它**不是** `runExclusiveWithSync`（整轮自动同步的互斥）：那把锁跨越全部网络
/// 通道，本机跑一轮云同步可以持有它好几分钟，对端的小请求排在后面就会在客户端
/// 15s 超时（BUG-2717 的原始症状）。这把锁只包本地 DB 的读-改-写，持有时间是毫秒
/// 到百毫秒量级。
///
/// 规则：
/// - 持锁期间**不得**发网络请求；
/// - 持锁期间**不得**再取 `runExclusiveWithSync` 或本锁（非重入，会死锁）。锁序
///   只允许「整轮同步锁 → 本锁」，反过来不行。
Future<T> runExclusiveWithSyncStateApply<T>(Future<T> Function() body) =>
    _syncStateApplyMutex.withLock(body);

final AsyncMutex _syncStateApplyMutex = AsyncMutex();
