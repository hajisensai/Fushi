# 备份导入"保留本机设置/Profile"开关 — 设计文档

- 日期：2026-05-30
- 状态：设计已确认（用户批准，默认关），待实现
- 范围：`hibiki/lib/src/sync/backup_service.dart` 导入流程 + 导入确认弹窗 + 启动恢复钩子
- 前置：本功能建立在已完成的"同步与备份配置重排"（2026-05-30）之上，复用其 sidecar/`recoverPendingImport`/`pre-restore.bak` 机制。

## 1. 需求

当前"导入备份"是整库覆盖：除"设备本地同步配置"（`deviceLocalPrefKeys`）被保留外，**所有偏好与内容都被备份覆盖**——包括字体、外观、阅读设置、Profile。用户希望：**导入备份时只恢复"内容"（书/进度/统计…），保留本机的设置与 Profile（字体/外观等）。**

## 2. 决策

| 决策点 | 结论 |
|--------|------|
| 交互 | 导入确认弹窗加开关「导入设置与 Profile（含字体/外观/阅读）」 |
| 默认 | **关**（默认保留本机设置，只恢复内容） |
| 开 | 完整恢复 = 现状（同步配置仍始终设备本地） |
| 关 | 保留本机"设置层"，只从备份恢复"内容层" |

## 3. 表分层（关键数据结构）

由 [database.dart:28-50](../../packages/hibiki_core/lib/src/database/database.dart#L28-L50) 的 21 张表确定：

**设置层（开关关时保留本机）：**
- `preferences`（活动设置：字体/外观/阅读/词典配置 + 同步配置）
- `profiles`、`profile_settings`（Profile 列表 + 每 Profile 快照）
- `media_type_profiles`、`book_profiles`（Profile 绑定）

**内容层（始终从备份恢复）：** 其余 16 张表（`epub_books`/`reader_positions`/`reading_statistics`/`bookmarks`/`reading_hourly_logs`/`audiobooks`/`audio_cues`/`srt_books`/`book_tags`/`book_tag_mappings`/`srt_book_tag_mappings`/`dictionary_metadata`/`dictionary_history`/`media_items`/`anki_mappings`/`search_history_items`）。

**FK 安全性（已核实 [tables.dart:249-294](../../packages/hibiki_core/lib/src/database/tables.dart#L249-L294)）：** 设置层只有内部 FK（`profile_settings`/绑定 → `profiles`，CASCADE）；`book_profiles.bookUid` 是纯 text（**无** FK 到 `epub_books`）；无内容表 FK 到 `profiles`。故"保留设置层 + 覆盖内容层"两个方向都不违反外键。恢复顺序：先 `profiles`，再其依赖表。

## 4. 实现（schema 安全：迁移后做表拷贝；**inline 执行**）

`importBackupFiles` 是整文件覆盖；覆盖后主库可能是**旧 schema**（旧备份）。恢复设置层时先 `HibikiDatabase(dir)` 打开主库——首条语句即触发 open+迁移到当前 schema，再 `ATTACH pre-restore.bak`（当前 schema）做按列对齐的表拷贝。

**关键：恢复 inline 在 `importBackupFiles` 内同步完成**（不再延迟到启动），所以常规路径不依赖 `pre-restore.bak` 跨重启存活，消除"bak 丢失→静默丢设置"的数据丢失窗口（评审 HBK-REV High-2）。覆盖前写入的 sidecar + bak 仅作**崩溃恢复网**：若 `importBackupFiles` 中途崩溃，下次启动 `recoverPendingImport` 据 sidecar 完成恢复。`_restoreSettingsLayer` 在 bak 缺失时不静默——`debugPrint` 记录。

### 4.1 `importBackupFiles({..., bool importSettings = true})`
- 新增参数 `importSettings`，**方法默认 true**（保持现有调用方/测试的完整导入语义；UI 传入开关值，默认 false）。
- `importSettings == true`（开）：**完全沿用现状**——保留 `deviceLocalPrefKeys`、清陈旧 folder cache、删 sidecar+bak。
- `importSettings == false`（关）：
  - 仍照常 `pre-restore.bak`（本机当前库副本）。
  - sidecar 写入标记 `{"mode":"settings"}`（而非 prefs map）。
  - **保留** `pre-restore.bak`（启动恢复要用），不立即删。
  - 不做 deviceLocalPrefKeys 再应用（整设置层将在启动时拷回）。

### 4.2 `recoverPendingImport(dbDirectory)`（启动钩子，已存在，扩展）
读 sidecar 的 `mode`：
- `mode == "prefs"`（开模式的崩溃恢复，现状）：再应用保留的 prefs（现有逻辑）。
- `mode == "settings"`（关模式）：
  1. 打开主库（已迁移到当前 schema）。
  2. `ATTACH DATABASE '<pre-restore.bak>' AS bak`。
  3. 事务内，按依赖顺序把设置层从 bak 拷回 main：
     - `preferences`：替换为本机的，**但排除 `audiobook_pos_%`**（有声书进度属内容，跟随备份的书）：
       `DELETE FROM main.preferences WHERE key NOT LIKE 'audiobook_pos_%';`
       `INSERT INTO main.preferences SELECT * FROM bak.preferences WHERE key NOT LIKE 'audiobook_pos_%';`
     - `profiles` → `profile_settings` / `media_type_profiles` / `book_profiles`：各 `DELETE FROM main.<t>; INSERT INTO main.<t> SELECT * FROM bak.<t>;`（profiles 先于其依赖）。
  4. `DETACH bak`，`PRAGMA wal_checkpoint(TRUNCATE)`。
  5. 清理 `pre-restore.bak` + sidecar。
- 既有的 `mode` 缺省/旧格式（纯 prefs map）按 prefs 处理（向后兼容）。

### 4.3 sidecar 格式
统一为 `{"mode": "prefs"|"settings", "prefs": {...}?}`。开模式崩溃恢复写 `{"mode":"prefs","prefs":{...}}`；关模式写 `{"mode":"settings"}`。

### 4.4 导入确认弹窗（`_BackupImportWidget._showConfirmDialog`）
- 用 `StatefulBuilder` 加一个开关「导入设置与 Profile」，默认 **关**。
- 弹窗返回"是否确认 + 开关值"；`_import()` 把开关值传入 `importBackupFiles(importSettings: ...)`。
- 关时弹窗副文案提示"将保留本机的字体/外观/Profile，只恢复书籍与阅读数据"。

## 5. 行为矩阵

| 场景 | 开（完整恢复） | 关（保留本机设置，默认） |
|------|----------------|--------------------------|
| 字体/外观/阅读 | 来自备份 | **保留本机** |
| Profile 及快照/绑定 | 来自备份 | **保留本机** |
| 同步配置（凭据/后端/服务器） | 设备本地保留 | 设备本地保留 |
| 书/进度/统计/标签/词典/有声书 | 来自备份 | 来自备份 |
| 有声书进度 `audiobook_pos_*` | 来自备份 | **来自备份**（跟随书） |
| 全新设备（本机无库） | 完整恢复 | 完整恢复（无本机设置可留，开关无效） |

## 6. 已知边界（直说）

- 关模式下，备份的书若 `bookUid` 与本机 `book_profiles` 不匹配，则用活动 Profile（不崩，绑定为孤儿行、无害）。
- 关模式保留本机 Profile 集合；备份里的 Profile **不导入**（这是用户明确要的）。

## 7. 测试

- 关模式：本机设字体/外观 pref + Profile + 绑定；备份含不同设置 + 书；`importBackupFiles(importSettings:false)` → 启动 `recoverPendingImport` → 断言设置/Profile/绑定为本机、书来自备份、`audiobook_pos_*` 来自备份。
- 开模式：现有 153 测试 + 完整恢复路径不回归。
- 全新设备（无本机库）关模式：完整恢复（开关无效）。
- 旧 schema 备份关模式：迁移后表拷贝列对齐、不报错。
- FK：恢复后 `PRAGMA foreign_key_check` 无违规。
- `dart format` + `flutter analyze` + `flutter test test/sync`。

## 8. 范围外

- 更细粒度（按类别勾选恢复哪些）——本次只做"设置层 vs 内容层"一个开关。
