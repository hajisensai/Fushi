/// 同步通道账本作用域（从 app 的 sync_repository.dart 抽出，互联 host 与引擎的
/// 聚合同步都按它分账）。
library;

import 'package:fushi_engine/sync/sync_backend_type.dart';

/// 一条同步通道在**持久化偏好键**里的身份（BUG-1576 / BUG-1578 / BUG-1579 / BUG-1580）。
///
/// 互联从「互斥的 `backendType` 单选」解耦成「与云备份并存的第二通道」之后，一轮
/// sweep 会在同一把锁里依次跑两条通道，而一批「一台设备只对一个远端」的状态仍是
/// **全局单份键**：folder 缓存、合集/删除墓碑因果基线、同步冷却戳、聚合快照哈希。
/// 后写者覆盖先写者，下一轮先读者读到的就是别人的账。最严重的一例是 folder 缓存
/// ——互联与 WebDAV 的 folderId 是**绝对 URL**，被另一条通道读回后会把请求连同
/// 自己的 Basic 凭据直接发往对端主机。
///
/// 所以凡是「按远端记账」的持久化状态都必须带上这个槽位标识。槽位取自通道身份：
/// - [forBackendType]：本机作为 client 跑的一条通道（云备份后端 / 互联）。互联恒
///   为 [SyncBackendType.fushiServer]，故「云 vs 互联」天然分开；用户把备份后端也
///   选成互联时两条通道会被去重成一条，槽位同样只有一个，语义仍然自洽。
/// - [host]：本机作为互联 host 被动接收对端 POST 时记的那本账（不是一条 client
///   通道，但同样是独立的因果轴）。
/// - [unscoped]：没有声明通道身份的后端（只可能是测试 fake，见
///   [syncChannelScopeOf]）。单独一格，绝不与任何真实通道共用。
class SyncChannelScope {
  const SyncChannelScope._(this.id);

  /// 本机作为 client 跑的一条通道（云备份后端 / 互联）。
  factory SyncChannelScope.forBackendType(SyncBackendType type) =>
      SyncChannelScope._(type.name);

  /// 本机作为互联 host 被动接收对端 POST 时那本账。
  static const SyncChannelScope host = SyncChannelScope._('host');

  /// 未声明通道身份的后端（测试 fake）。
  static const SyncChannelScope unscoped = SyncChannelScope._('unscoped');

  /// 从 [id] 还原槽位（跨「报告 → UI」这类只搬得动纯数据的边界时用；id 本身就是
  /// 这个类产出的，故是无损往返）。
  factory SyncChannelScope.byId(String id) => SyncChannelScope._(id);

  /// 全部可能的槽位（键目录展开用，见 [SyncRepository.deviceLocalPrefKeys]）。
  static List<SyncChannelScope> get all => <SyncChannelScope>[
        for (final SyncBackendType t in SyncBackendType.values)
          SyncChannelScope.forBackendType(t),
        host,
        unscoped,
      ];

  final String id;

  /// 把一个全局键基名加上本槽位后缀。双下划线分隔：既不会与任何既有的
  /// snake_case 键撞成同名，也一眼看得出哪部分是基名。
  String key(String base) => '${base}__$id';

  @override
  bool operator ==(Object other) => other is SyncChannelScope && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SyncChannelScope($id)';
}
