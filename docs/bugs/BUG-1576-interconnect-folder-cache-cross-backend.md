## BUG-1576 · 互联/云双通道共用 folder 缓存：跨后端串味 + 凭据外发到对端主机
- **报告**：2026-08-12（用户：审计）
- **真实性**：✅ 真 bug（沿双通道 sweep 的真实代码路径核实）

### 根因
互联从「互斥的 `backendType` 单选」解耦成「与云备份并存的第二通道」后，
`enabledSyncChannelBackends`（`fushi/lib/src/sync/sync_auto_trigger.dart:156-178`）在**同一把锁、
同一个循环**里依次跑两条通道（云恒排 index 0、互联在后），而根 folderId / 书名→folderId 映射
仍是**单份全局键**：

- `fushi/lib/src/sync/sync_repository.dart:86-87` —— `sync_root_folder_id` / `sync_folder_cache`
  是与后端身份无关的两个全局键。
- `fushi/lib/src/sync/sync_manager.dart:942-966` —— `_restoreDriveCache` / `_persistDriveCache`
  无条件读写这两个键；`fushi/lib/src/sync/sync_orchestrator.dart:516` 附近两条通道各构造一次
  `SyncManager`。

于是一轮 sweep「云先写、互联后写」，磁盘上留下的是**互联对端的绝对 URL**
（`fushi/lib/src/sync/interconnect_sync_backend.dart:352-386` 的 folderId 形如
`https://peer.lan:8443/hibiki-data/<书>/`；`fushi/lib/src/sync/webdav_sync_backend.dart:86-89`
同为绝对 URL，且缓存非空即短路返回）。下一轮：

1. **凭据外发**：`fushi/lib/src/sync/webdav_ops.dart:103-108` 的 `buildRequest` 对绝对 URL 直接
   `openUrl` 并附上**本通道自己的** `Authorization: Basic`。per-book 路径
   （`fushi/lib/src/sync/sync_auto_trigger.dart:686` → `fushi/lib/src/sync/sync_manager.dart:290`）
   于是把 WebDAV 的书籍 JSON `PUT` 到互联对端主机上，WebDAV 账号密码一并送出。
2. **Drive 整通道 4xx**：Drive 把 URL 当 fileId 用。
3. **误判「云已配置」**：`fushi/lib/src/sync/sync_repository.dart:326-329` 的
   `hasStoredBackendConfig(googleDrive)` 含 `present(getRootFolderId())`；被污染后，一台从未登录
   过 Drive 的设备被判成「云已配置」，
   `fushi/lib/src/sync/deletion_propagation_availability.dart:26-33` 据此放行「从所有设备删除」
   ——墓碑写进本地表却无人发布，用户以为删干净了。

第二个跨后端恢复/回写点：`fushi/lib/src/sync/sync_compare_dialog.dart:419-427`（`_ensureRoot`
读全局键）与 `:295-299`（回写全局键）。

### 修复
folder 缓存按通道分槽：新增 `SyncChannelScope`（`sync_repository.dart`），键名 =
`<基名>__<槽位 id>`；槽位由 `syncChannelScopeOf(SyncBackend)`（`sync_backend.dart`，
`resolveSyncBackend` 的逆，对 `SyncBackendType.values` 逐值有守卫）从后端实例反查。
`SyncManager` / `SyncOrchestrator` / 对比对话框 / 登出 / 切后端一律带槽位。

**迁移语义**：旧全局 `sync_root_folder_id` / `sync_folder_cache` **丢弃而不搬运**
（`migrateFolderCacheToPerChannel`，init 期跑一次，幂等）。理由：那个值此刻已无法归因到任何一条
通道（正是本 bug 的成因），搬进任一槽位都等于固化污染；而它是**纯缓存**——根目录由
`findOrCreateRootFolder` 按名查找/创建、书文件夹由 `ensureBookFolder` 按名解析，丢了只是下一轮
多几次目录解析，零数据损失（切后端本来就会清它）。备份导入改用 `clearAllFolderCaches()`
（清全部槽位 + 旧全局键）。

- **[x] ① 已修复** — 见本文件所在提交
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_channel_scope_test.dart`
  （槽位反查穷尽性 / 跨槽位不可见 / 迁移不搬运 / `hasStoredBackendConfig` 不被污染 /
  `clearAllFolderCaches`）；变异实测：把 webDav 的槽位映射改成 googleDrive → 用例红。
- **备注**：`SyncChannelScope.unscoped` 是测试 fake 的独立一格，绝不与真实通道共用。
