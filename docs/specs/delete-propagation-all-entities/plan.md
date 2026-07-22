# 删除传播（全实体）实现计划 — v2（对齐现存统一机制）

> 状态：**已确认，实施中**。分支 `worktree-delete-propagation-all-entities`，基底 `247dcc285`。
> ⚠️ v1 的「按实体分表」方案已作废——与仓库已存在的统一表 `SyncDeletionTombstones` 冲突。本 v2 基于现存机制补全。

## 用户三项确认（2026-07-22）
1. 弹窗**不存在**，从零建（源设备删除时选「同步删除 / 仅本机保留」）。
2. 上线节奏：**一次性全做完 + 双设备真机验收后再开 PR**。
3. 实体范围：**全部**——书/SRT/视频/有声书/本地音频/词典/合集/统计 + 标签/Profile/书签/收藏词句/搜索历史。
4. UX 模型（2026-07-22 二次确认）：**源设备弹窗决定「同步删除/仅本机」+ 接收端同步时逐条确认**「另一设备删了X，本地也删？」。**与现有 `deletion_propagation.dart` 设计意图一致**，决策核心照原样复用不改语义。仍加 `remotePublishedAt` vs 基线因果守卫防旧墓碑反复弹。

## 现存基建盘点（基底已提交、干净）

**媒体资产统一墓碑机制（半成品）**：
- ✅ 表 `SyncDeletionTombstones`（mediaType, itemKey, deletedAt, remotePublishedAt），`tables.dart:964-981`
- ✅ DB 方法 `database.dart:4727-4760`：write / clear / get / getOfType / markPublished
- ✅ 写墓碑已接：book(`reader_hibiki_source.dart:744`) / video(`video_book_repository.dart:347`)
- ✅ 清墓碑已接：book(`database.dart:3827`) / video(`database.dart:2116`)
- ✅ 纯决策核心 `computeDeletionPropagation` + 编解码 `deletion_propagation.dart`（命名空间 `__tombstones__`）
- ✅ 单测：`test/database/sync_deletion_tombstone_test.dart` + `test/sync/deletion_propagation_test.dart`
- ❌ **发布层不存在**（无人读墓碑发布到云/host）
- ❌ **消费层不存在**（`computeDeletionPropagation` / `parseDeletionTombstoneJson` 零生产调用）
- ❌ audiobook / localaudio 从不写墓碑

**已闭环的独立删除传播（保留，不动）**：
- ✅ 合集：`collection_sync_engine.dart`（墓碑 + publishedAt 因果 + 真删对端），三后端都消费。
- ✅ 词典：BUG-086 `deleteRemoteDictionaryAsset`（`sync_orchestrator.dart:102`）独立链，已闭环。

**只防复活、未传播**：
- ⚠️ 书 `book_tombstones`（仅备份合并防复活）；统计 `statistics_tombstones`（仅 MAX-union 防复活）；标签 `book_tag_membership_tombstones`（LWW，需核实是否已跨端）。

## 决策核心复用（不改语义）

现有 `computeDeletionPropagation` 产出**双向候选待确认**，正好是要的。消费端：
- `deleteLocal` 候选（远端有墓碑 ∧ 本地在库）→ 弹**逐条确认**框「另一设备删了X，本地也删？」，用户勾选后删本地（含已下载磁盘）。
- `deleteRemote` 候选（本地删、远端还在）→ 本设备发布墓碑到远端即可，靠远端设备各自消费确认。
- 因果守卫：`remotePublishedAt`/`deletedAt` vs 本设备该资产同步基线，旧闻不反复弹；用户明确"忽略/保留"过的墓碑记录跳过，不反复骚扰。

## 分阶段实施（一次性交付，但分层推进保证每步可编译可测）

### Phase A — 前端统一删除弹窗 + scope 意图
- 新增 `enum DeleteScope { keepLocalOnly, syncEverywhere }`。
- 统一/改造删除确认弹窗提供 scope 选择，覆盖入口：书/SRT/视频(`reader_history/dialogs.part.dart` + `_confirmMediaDelete`)、有声书(`audiobook_import_dialog.dart:1064`)、词典(`dictionary_dialog_page.dart:385`)、合集(4处)、统计(`stat_delete_confirm_dialog.dart`)、本地音频。
- 弹窗返回 `DeleteScope?`（null=取消）。
- i18n 走 `tool/i18n_sync.dart`（17 语言）：`delete_scope_title/sync_everywhere/keep_local/hint`，再 `dart run slang`。

### Phase B — 写墓碑接全实体 + 消费 scope
- 各 delete 方法按 scope 写 `SyncDeletionTombstones`：`syncEverywhere`→写墓碑；`keepLocalOnly`→不写传播墓碑（仅本机现有防复活语义）。
- 补全写入点：audiobook(`deleteAudiobookByBookKey` database.dart:2100)、localaudio(`deleteLocalAudio` app_model_library_host_service.dart:612)、词典（决定并入统一表还是保留 BUG-086 独立链——倾向保留独立链，避免破坏已闭环逻辑）。
- 标签/统计/合集：沿用各自已有墓碑表，Phase C 里接发布/消费；书签/收藏词句/Profile/搜索历史：评估最小墓碑载体。

### Phase C — 发布层（读墓碑→远端标记）
- 云路径(Drive/WebDAV/Dropbox…)：读 `getSyncDeletionTombstones`(remotePublishedAt==0) → `ensureNamespace('__tombstones__')` → 逐条 `putJsonAsset(deletionTombstoneAssetName, deletionTombstoneJson)` → `markSyncDeletionPublished`。接入 `sync_orchestrator.dart` 同步主流程。
- 互联 host 路径：host 暴露 `/api/tombstones` GET（列本机墓碑）；client 经 `hibiki_client_sync_backend.dart` 拉取。老 host 404 优雅降级。

### Phase D — 消费层（读远端标记→逐条确认→删本地）
- 云 + 互联各自：拉远端 `__tombstones__` / host 墓碑 → `parseDeletionTombstoneJson` → 组装 remoteTombstones + 本地在库键 → `computeDeletionPropagation` → 得 `deleteLocal` 候选。
- 过因果守卫（deletedAt > 基线 且 未被用户忽略过）后，**弹逐条确认框**「另一设备删了这些，本地也删？」（复用/新建候选列表 UI，参考现有 `sync_compare_dialog.dart` 样式）。
- 用户确认 → 调对应 raw 删除（`deleteEpubBook`/`deleteVideoBook`/`deleteAudiobook`… 传「同步专用、不写新墓碑、不再触发发布」标志）+ 删磁盘缓存（用户选「已下载也删」）→ 推进该资产同步基线/记「已处理」防反复弹。
- 用户拒绝某条 → 记「已忽略」，不反复弹（但保留，未来语义变化可再评估）。

### Phase E — 备份整库合并消费源侧墓碑
- `backup_merge_engine` 扩展：读**源侧** `sync_deletion_tombstones` + 各实体墓碑表，过因果安全阀后对目标删除。最高数据丢失风险，最严格测。

### Phase F — 收尾
- 孤儿清理（删书清 reader_positions）。
- `dart format .` + `flutter analyze`（含 test）+ `flutter test`。
- BUG 文件：`importRemoteBooks` 复活缺口（一 bug 一文件 + 守卫测试）。
- 双设备真机验收原始失败路径（A 删→B 同步 B 本地消失；删后重加不误删）。
- bump `pubspec.yaml` +build，开草稿 PR。

## 风险点
- 🔴 自动删 + 已下载也删 = 强破坏力。缓解：源端显式弹窗 + 因果安全阀（基线守卫）+ Phase D/E 最严格测 + 真机验收。
- 🔴 备份旧墓碑误删新数据 → publishedAt/deletedAt vs 基线守卫（Phase E）。
- 🟡 词典/合集已有独立闭环，勿双轨打架——倾向保留、不并入统一表。
- 🟡 散落 6+ 删除入口，弹窗改造需逐一覆盖不漏旧路径。
- 🟡 老 host 兼容：`/api/tombstones` 404 优雅降级。

## 参考
- 合集协议精读：`reference-collection-protocol.md`
- 现存脊柱：`hibiki/lib/src/sync/deletion_propagation.dart`（纯核心+编解码，待接线）
