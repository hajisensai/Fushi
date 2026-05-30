# 同步与备份配置重排 — 设计文档

- 日期：2026-05-30
- 状态：设计已确认，待写实现计划（writing-plans）
- 范围：`hibiki/lib/src/sync/` 同步设置页层级重排 + 后端清理 + 三项同步/备份行为根因修复
- 执行原则：彻底根因实现，不用"图省事但难维护"的方案；实现后进入 审查→修复→循环 直到 Opus code review 通过（见 CLAUDE.md 强制流程）

---

## 1. 背景与问题

当前"同步与备份"设置页（[hibiki/lib/src/sync/sync_settings_schema.dart](../../hibiki/lib/src/sync/sync_settings_schema.dart)）把 7 个区段**无差别铺给所有后端**：只有"每后端的凭据框"(WebDAV/FTP/SFTP/SMB/Hibiki) 有 `visible:` 门控；而 **启用同步服务器、局域网设备、账户/登录、同步选项** 四段对任何后端都恒显示。

由此产生的"对某些后端根本不存在的配置项"：

- **账户/登录** 段对所有后端显示，但"登录"只对 OAuth 云后端（Google Drive / OneDrive / Dropbox）有意义；WebDAV/FTP/SFTP 的认证就是在配置框里填账密。
- **启用同步服务器 + 局域网设备** 只属于 Hibiki P2P 场景，却铺给 Google Drive 等云后端。
- **SMB** 是个假后端：无原生 SMB，只是 WebDAV 网关（详见 §4），且带 3 个永不读取的死 key。

另有三项审查发现的同步/备份行为缺陷（本次一并根因修复，见 §6）。

## 2. 目标

1. 按"后端认证范式"分类，把每个配置项**只在其适用后端下渲染**。
2. **真正重排页面层级**（分组、分区标题、组内视觉层级），不只是加显示判断。
3. 移除假 SMB 后端、并入 WebDAV，带老用户迁移；清理死 key。
4. 根因修复 folder_cache 清缓存、audiobook_pos 绕过仓库、备份导入抹掉本机同步配置三项。
5. 零破坏：现有已配置用户（含 SMB 用户）升级后继续可用。

## 3. 已确认决策

| 决策点 | 结论 |
|--------|------|
| 重构深度 | 分组重组 + 作用域门控（含真正的 UI/分组重做） |
| SMB | 并入 WebDAV、移除假 SMB 后端，带一次性启动迁移 |
| 改动范围 | UI 与数据模型一起清 |
| i18n | 全新 key，不复用旧的（统一 `sync_section_*` 命名） |
| F 区相邻问题 | 三项全做（folder_cache / audiobook_pos / 备份导入） |
| 服务器组默认形态 | 始终展开 |
| 导入·凭据/backend/服务器配置 | 设备本地，**必保留** |
| 导入·folder_cache | **重建**，不还原（避免陈旧 ID） |
| 导入·行为开关(auto/stats/audiobook/content) | **从备份恢复**（当作用户设置） |
| 导入·崩溃安全 | 旁路 sidecar JSON 先落盘再交换 |
| 导入·pre-restore.bak | 成功即删 + 启动清扫 |
| 外来备份 UX | 静默保留本机同步配置 + 导入确认弹窗加一行说明；不做勾选框 |

## 4. 后端分类（数据结构优先）

所有显示逻辑由这张分类表派生，不再散落 `switch`：

| 类别 | 后端 (`SyncBackendType`) | 认证方式 | 在"同步方式"组里显示 |
|------|------|---------|----------------------|
| OAuth 云 | `googleDrive` / `oneDrive` / `dropbox` | 浏览器登录 | 账户/登录状态 |
| 凭据远程 | `webDav` / `ftp` / `sftp` | 配置框填账密 | 对应配置框（含测试连接） |
| P2P/局域网 | `hibikiServer` | URL 列表 + 令牌 | P2P 配置框 + 局域网发现 |
| ~~SMB~~ | **删除 `smb`** | — | 迁移到 WebDAV |

新增纯函数 `bool _isOAuthBackend(SyncBackendType)`，账户段门控走它。

### 为什么删 SMB

[hibiki/lib/src/sync/smb_sync_backend.dart](../../hibiki/lib/src/sync/smb_sync_backend.dart) 类注释自述：无 pure-Dart SMB 库，要求用户自架 SMB→WebDAV 网关并粘贴 WebDAV URL。逐行比对 SMB 与 WebDAV 后端：同一个 `WebDavOps`、同一根路径 `${baseUrl}/ttu-reader-data/`、同样的 PROPFIND/GET/PUT/MKCOL/DELETE，唯一区别是存储 key 前缀。`host/share/domain` 三个 key 存了却永不读取。它是 WebDAV 的重复后端 + 死字段。原生 SMB 对本 app（只同步几 KB JSON）跨 5 平台实现代价极高、收益极低，且自托管场景已被 WebDAV/FTP/SFTP 覆盖，故消除而非实现。

## 5. 新层级（5 组 + 可见性矩阵）

```
同步与备份
│
├─[组1] 同步方式 (Sync method)              ← 所有后端可见
│    • 后端选择 (下拉)
│    • 账户/登录          ← 仅 OAuth 云（原"账户"段移入，与凭据框同槽位）
│    • WebDAV 配置框      ← 仅 webDav
│    • FTP 配置框         ← 仅 ftp
│    • SFTP 配置框        ← 仅 sftp
│    • Hibiki P2P 配置框  ← 仅 hibikiServer
│    • 发现局域网设备     ← 仅 hibikiServer（从顶层段下沉到 P2P 作用域）
│
├─[组2] 本机作为同步服务器                  ← 始终可见、始终展开
│    • 启用服务器 + 端口 + 访问令牌
│    footer: "让其他设备连到本机同步，与上面的同步后端互不影响"
│
├─[组3] 同步内容 (What to sync)             ← 全局
│    • 自动同步 / 同步统计 / 同步有声书进度 / 同步书籍文件
│
├─[组4] 同步操作                            ← 全局
│    • 对比数据
│
└─[组5] 本地备份                            ← 独立功能
     • 导出备份 / 导入备份
```

可见性矩阵（由 `SettingsDestination.visibleSections` 实现；空 section 自动隐藏，已核实 [settings_destination.dart:58-63](../../hibiki/lib/src/settings/settings_destination.dart#L58-L63)）：

| 后端 | 账户 | WebDAV | FTP | SFTP | P2P+LAN | 服务器 | 内容/操作/备份 |
|------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| googleDrive/oneDrive/dropbox | ✓ | – | – | – | – | ✓ | ✓ |
| webDav | – | ✓ | – | – | – | ✓ | ✓ |
| ftp | – | – | ✓ | – | – | ✓ | ✓ |
| sftp | – | – | – | ✓ | – | ✓ | ✓ |
| hibikiServer | – | – | – | – | ✓ | ✓ | ✓ |

实现要点：
- `_BackendSelectorWidget.onChanged` 已调 `settingsContext.refresh()`（[:919](../../hibiki/lib/src/sync/sync_settings_schema.dart#L919)），切后端即重算可见性。
- 账户段从独立 section 移入组1，并加 `visible: (ctx) => _isOAuthBackend(_syncSettings(ctx).backendType)`。
- LAN 发现项加 `visible: hibikiServer`，置于 P2P 配置框之后。
- 服务器、内容、操作、备份各成一组，标题用新 i18n key。

## 6. 同步/备份行为根因修复（F 区，三项全做）

### F1. folder_cache：移除"瞬时错误清空磁盘缓存"

- **真相**：auto-sync 确实在成功后持久化（[sync_manager.dart:66/82/130](../../hibiki/lib/src/sync/sync_manager.dart#L66)）。
- **根因**：可重试错误路径 [sync_manager.dart:70-71](../../hibiki/lib/src/sync/sync_manager.dart#L70-L71) 同时 `_backend.clearCache()` + `await _repo.clearFolderCache()`，一次网络超时即清空磁盘缓存，重试及后续会话全量重做文件夹查找，直到下次完全成功。
- **修法**：重试路径保留 `_backend.clearCache()`（丢内存态），**删除 `_repo.clearFolderCache()`**。陈旧 ID 自愈：后端拒绝（404/auth）→ 重走错误路径重新解析。
- **保留不动**：后端切换 [:918](../../hibiki/lib/src/sync/sync_settings_schema.dart#L918) 与登出 [:412](../../hibiki/lib/src/sync/sync_settings_schema.dart#L412) 的 `clearFolderCache()`（有意失效）。
- **无** schema/key/格式变更。

### F2. audiobook_pos：统一走 SyncRepository

- **现状**：`audiobook_pos_${book.id}`（int 毫秒，默认 0）在 3 处直打 `_db.getPrefTyped/setPrefTyped`：写 [sync_manager.dart:348](../../hibiki/lib/src/sync/sync_manager.dart#L348)、读 [sync_manager.dart:445](../../hibiki/lib/src/sync/sync_manager.dart#L445)、读 [sync_compare_dialog.dart:139](../../hibiki/lib/src/sync/sync_compare_dialog.dart#L139)。
- **修法**：SyncRepository 增 `static const _keyAudiobookPositionPrefix = 'audiobook_pos_'` + `Future<int> getAudiobookPosition(int bookId)`（默认 0）/`Future<void> setAudiobookPosition(int bookId, int positionMs)`，3 处改走它。保留 compare 的 `0→null` 映射（[:140](../../hibiki/lib/src/sync/sync_compare_dialog.dart#L140) 的 nullable 契约）。
- **不动**：`packages/hibiki_audio/.../audiobook_repository.dart:93-103` 的同前缀非同步播放访问器。
- **无迁移**（key 与 int 序列化不变）。

### F3. 备份导入：让导入"懂"偏好表，不再整库覆盖

- **真相**：导出剥离全部密钥（[backup_service.dart:139-153](../../hibiki/lib/src/sync/backup_service.dart#L139-L153)，正确、保留）；导入是整文件覆盖（[backup_service.dart:179-199](../../hibiki/lib/src/sync/backup_service.dart#L179-L199)），`pre-restore.bak` 写了却从不读。结果：导入任何备份都清空本机 `sync_backend_type` + 全部凭据/令牌/服务器配置/folder_cache。
- **修法**：
  1. **SyncRepository 暴露"设备本地 key 目录"为唯一真相源**：新增 `List<String> deviceLocalPrefKeys`（或返回精确 key + 前缀的分类器），含 `sync_backend_type` + 全部凭据/令牌（`sync_desktop_credentials`、`sync_dropbox_token`、`sync_onedrive_token`、`sync_webdav_*`、`sync_ftp_*`、`sync_sftp_*`、`sync_server_*`、`sync_hibiki_client_*`）。导入逻辑只引用它，杜绝 key 清单漂移。
  2. `importBackupFiles` 交换**前**：开当前库读出这些 key → 写入**旁路 sidecar JSON**（不能只放内存：导入后 app 强制退出且库已关，崩溃中途会永久丢凭据）。
  3. 交换**后**：开新库写回这些 key → VACUUM + `PRAGMA wal_checkpoint(TRUNCATE)` 落盘。
  4. `sync_folder_cache`/`sync_root_folder_id` **不还原**，下次同步重建（与 F1 自愈对齐）。
  5. 行为开关 `sync_auto_enabled`/`sync_stats_enabled`/`sync_audiobook_enabled`/`sync_content_enabled` **从备份恢复**（不在保留清单内）。
  6. 成功后删 `pre-restore.bak` + sidecar；启动时清扫残留（修磁盘泄漏）。
  7. 导入确认弹窗（[sync_settings_schema.dart:767-798](../../hibiki/lib/src/sync/sync_settings_schema.dart#L767-L798)）加一行说明"本设备同步配置将保留"。

### 跨条共识与实现顺序

- 全为 preferences 键值层：**无 Drift schema bump、无迁移、无 `*.g.dart` 重生成**。
- `audiobook_pos_*` 属内容，**不进**设备本地保留清单（应随备份恢复）。
- 顺序：**F2（纯搬移，最低风险）→ F1（小而局部）→ F3（最大，依赖设备本地 key 清单）**。

## 7. 数据模型清理（SMB 移除 + 迁移 + 死 key）

1. 移除：`SyncBackendType.smb`、`SmbSyncBackend`（删文件）、`_SmbConfigWidget`、`resolveSyncBackend`/`_backendLabel`/`_isBackendSelectable` 的 smb 分支、6 个 repo 访问器 + key 常量（[sync_repository.dart:324-355](../../hibiki/lib/src/sync/sync_repository.dart#L324-L355)）、SMB i18n（含旧 `sync_backend_smb` 与硬编码 `'WebDAV URL'` 标签 [:1342](../../hibiki/lib/src/sync/sync_settings_schema.dart#L1342)）。
2. **一次性启动迁移**（镜像现有 `sync_hibiki_client_url → sync_hibiki_client_urls` 先例，精确位置在 writing-plans 阶段定位）：
   - 若 `sync_backend_type == 'smb'`：把 `sync_smb_webdav_url/username/password` 搬到 `sync_webdav_url/username/password`（**仅当 webdav 对应项为空**，不覆盖已有 WebDAV 配置）；置 `sync_backend_type = 'webDav'`。
   - 无论是否迁移，删除全部 `sync_smb_*`（host/share/domain/webdav_url/username/password）。
   - `getBackendType` 对未知字符串兜底回 `googleDrive`，双保险。
   - 迁移须在任何同步代码解析 backend 类型**之前**运行（挂在 `AppModel.initialise()` 同步早段）。
3. `sync_ftp_use_tls` 残留：后端切走 ftp 时一并复位（低优先，顺手）。

## 8. i18n 计划

- **必须用 [hibiki/tool/i18n_sync.dart](../../hibiki/tool/i18n_sync.dart) 脚本**增删 key，禁止手改 17 份 `*.i18n.json`（CLAUDE.md 硬性）。
- 新增组标题（示例，最终在实现期定稿）：
  - `sync_section_method`（同步方式 / Sync method）
  - `sync_section_host_server`（本机作为同步服务器 / This device as sync server）
  - `sync_section_host_server_footer`（说明文案）
  - `sync_section_content`（同步内容 / What to sync）
  - `sync_section_actions`（同步操作 / Sync actions）
  - `sync_section_backup`（本地备份 / Local backup）
  - `backup_import_preserve_sync_note`（"本设备同步配置将保留" / "Your sync settings on this device will be kept"）
- 删除：`sync_backend_smb` 及其它仅 SMB 用的 key。
- 复用旧 key：按决策**不复用**，旧的 `sync_server_enable`/`sync_lan_discovery`/`sync_account` 等以新 key 取代（旧 key 若无其它引用则随 SMB 一起清）。

## 9. 改动文件清单

| 文件 | 改动 |
|------|------|
| `hibiki/lib/src/sync/sync_settings_schema.dart` | 重排 5 组、加作用域门控、账户段移入组1、LAN 下沉 P2P、删 `_SmbConfigWidget`、导入弹窗加说明 |
| `hibiki/lib/src/sync/sync_repository.dart` | 删 SMB 访问器+key；加 audiobookPos 访问器；加 `deviceLocalPrefKeys` |
| `hibiki/lib/src/sync/smb_sync_backend.dart` | **删除文件** |
| `SyncBackendType` 定义处（sync_backend.dart 或同处） | 删 `smb` 枚举值；`resolveSyncBackend` 删分支 |
| `hibiki/lib/src/sync/sync_manager.dart` | F1 删重试清缓存；F2 改走 audiobookPos 访问器 |
| `hibiki/lib/src/sync/sync_compare_dialog.dart` | F2 改走 audiobookPos 访问器（保留 0→null） |
| `hibiki/lib/src/sync/backup_service.dart` | F3 `importBackupFiles` 改为偏好感知（保留清单/sidecar/重建/清扫） |
| `hibiki/lib/src/models/app_model.dart` | 挂 SMB→WebDAV 启动迁移；启动清扫 pre-restore.bak/sidecar |
| i18n 源 + `strings.g.dart` | 经 `i18n_sync.dart` 脚本增删 |

## 10. 测试与验证

- **门控单测**：对每个 `SyncBackendType` 调 `destination.visibleSections(ctx)`，断言出现的 section/item id 集合符合 §5 矩阵（账户仅 OAuth、LAN 仅 hibikiServer、无 SMB 选项、服务器/内容/操作/备份恒显示）。`visibleSections` 是纯函数，可直接测。
- **SMB 迁移单测**：写入 `backend=smb`+`sync_smb_*`，跑迁移，断言 `backend=webDav`、`sync_webdav_*` 落地（不覆盖已有）、`sync_smb_*` 清空、`getBackendType` 不再返回 smb。
- **F1 单测**：模拟可重试错误后断言 `sync_folder_cache`/`sync_root_folder_id` 仍在；后端切换/登出后断言被清。
- **F2 单测**：新访问器与旧 `getPrefTyped` 读写互通（round-trip），导出/导入保留有声书位置。
- **F3 单测**：导入一份"已剥离密钥"的备份后，断言本机 `sync_backend_type`+凭据+服务器配置仍在、行为开关来自备份、folder_cache 已清待重建、`pre-restore.bak`/sidecar 已清；模拟交换后崩溃→重启能从 sidecar 恢复凭据。
- **命令**：`hibiki/` 下 `dart format .` + `flutter test`。Android manifest/权限/Gradle 无改动，**无需** `assembleRelease`。
- 真机/模拟器复测：导入/导出走真实路径，留证据。

## 11. 向后兼容与风险

- SMB 用户：启动迁移搬运配置到 WebDAV，无感继续可用；未配置 SMB 的用户仅删死 key。
- F1：陈旧文件夹 ID 最多延迟一次同步被后端拒绝后自愈，不会永久掩盖；缓存 ~1KB/100 本。
- F2：纯调用路径重构，key 与序列化不变，无迁移。
- F3：ZIP 格式/schema 不变，旧备份仍可导入；`pre-restore.bak`/sidecar 为本地、绝不进 ZIP；安全不变（密钥永不导出，只保留本机自身凭据）。须防的两点：保留缓存在写回前丢失（→ sidecar + 审计日志）、外来备份静默保留本机配置（→ 弹窗说明）。

## 12. 本次范围外（未来）

- 备份导入"用备份替换同步配置"的显式勾选框（本次只静默保留 + 文案）。
- 原生 SMB/CIFS（如确需，另起独立大工程 spec）。
- 其它 per-book 有声书设置（speed/delay/follow）的同步访问器（YAGNI，未同步前不加）。
- 导出侧密钥 LIKE 模式是否覆盖未来新增凭据 key 的长期维护问题。
