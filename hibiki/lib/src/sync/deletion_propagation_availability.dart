/// 「从所有设备删除」这个选项此刻**能不能兑现**的唯一判据（TODO-2470 死角②）。
///
/// 背景：删除确认框的「从所有设备删除」勾选框原先恒亮。本机一个同步后端都没配时勾上
/// 它，墓碑写进本地表、`remotePublishedAt` 永远是 0、无人发布——用户以为删干净了，
/// 实际只删了本机，且全程零提示。没有通道时跨设备删除**物理上不可能**，所以「做实」
/// 只能是让控件的可用性由真实通道状态派生，而不是继续摆一个兑现不了的承诺。
///
/// 判据与同步真正跑的那套**同源**：通道枚举直接复用 [enabledSyncChannelBackends]
/// （云备份通道 + 已启用的互联通道），不在这里重抄一遍，否则两处迟早漂开。
library;

import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_repository.dart';

/// 本机是否存在可用于删除传播的同步通道。
///
/// 每条通道满足任一即算存在：
/// - [SyncRepository.hasStoredBackendConfig]：凭据/地址已落盘。**离线也算**——墓碑会
///   留在本地等下次同步发布，这是正确行为。
/// - `backend.isAuthenticated`：会话已在内存里恢复。补的是移动端 Google 登录态
///   不落 preferences 的缺口。
///
/// **零网络**：7 个后端的 `isAuthenticated` 全是 `_x != null` 式内存读（与
/// `_runSyncChannel` 用的是同一个门），`hasStoredBackendConfig` 是 preferences 读。
/// 这里**绝不能**调 `restoreAuth`——互联后端的 `restoreAuth` 会探测对端地址，而本函数
/// 跑在删除确认弹窗弹出前的 UI 路径上。
Future<bool> hasDeletionPropagationChannel(SyncRepository repo) async {
  for (final SyncChannel channel in await enabledSyncChannelBackends(repo)) {
    if (await repo.hasStoredBackendConfig(channel.type)) return true;
    if (await channel.backend.isAuthenticated) return true;
  }
  return false;
}
