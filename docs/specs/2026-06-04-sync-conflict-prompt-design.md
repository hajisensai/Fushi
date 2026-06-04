# 同步冲突弹窗确认 — 设计文档

- 日期：2026-06-04
- 分支：develop
- 状态：设计已与用户确认范围（进度=Phase 1，有声书位置=Phase 2），待用户复核本 spec 后出实现计划。

## 1. 背景与问题

当前所有同步路径（手动「立刻同步」`_syncNow` → `runManualFullSync`，以及开/关书触发的自动同步 `_runAutoSync`）遇到差异时，由 `SyncManager._determineSyncDirection`（`sync_manager.dart:259`）**静默自动解决**：

- 阅读进度：两端各有一个时间戳（本地 `ReaderPositions.updatedAt`，远端进度文件名里的 `lastBookmarkModified`），**时间戳新的一方胜（last-write-wins）**；时间戳同毫秒打平时再比进度比例（HBK-AUDIT-047）。
- 结果只在「立刻同步」结束时弹一个 SnackBar 摘要；自动同步无任何提示。

**真实痛点**：last-write-wins 没有「共同祖先/基线」概念，无法区分「单边改动（正常）」和「双边都改动（真分叉）」。当两台设备都读进过、但其中一台时间戳更新却内容更旧时，会把用户的真实进度静默盖回去，数据丢失且无感知。

唯一能手动选方向的入口是「比较数据 / Compare data」对话框（`SyncCompareDialog`），但它要用户主动打开，且它的 `hasConflict` 定义是「两端时间戳不相等」（`sync_compare_dialog.dart:55`）——过于宽松，几乎任何有差异的同步都算「冲突」。

## 2. 目标与范围

### 目标

让真正的**双边分叉冲突**在同步时浮出来，由用户选择保留哪一边，而不是被静默覆盖；单边改动仍照常自动同步，不打扰用户。

### 范围（与用户确认）

| 维度 | 处理 | 阶段 |
|---|---|---|
| **阅读进度（书签位置）** | 引入基线，真分叉弹窗确认 | **Phase 1（本 spec 详写）** |
| 有声书播放位置 | 真分叉弹窗确认，但需先理清存储/时间戳/方向 | **Phase 2（本 spec 仅记录发现）** |
| 阅读统计 | **保持** 逐字段 `max()` 自动合并（无损、可交换），**不弹** | 不做 |
| 书籍/词典 增删/版本 | **保持** 单边自动传播（资产同步已实现），**不弹**（不可编辑、不内容分叉） | 不做 |

### 非目标

- 不改统计合并策略。
- 不改书籍/词典资产的存在性同步（导入远端独有、compare 逐行删远端）。
- 不引入字段级三方合并（进度是单值，整段取本端或远端即可）。

## 3. 核心机制：基于基线的三方分叉检测

### 3.1 新增持久化：`SyncBaselines` 表

在 `hibiki_core` 新增一张小表（schema v14 → v15 迁移）：

```dart
class SyncBaselines extends Table {
  TextColumn get assetKey => text()();    // 跨设备书籍身份 = sanitizeTtuFilename(book.title)
  TextColumn get dimension => text()();   // 'progress'（Phase 2 再加 'audiobook'）
  IntColumn get baseVersion => integer()(); // 上次同步成功时双方一致的版本（进度=时间戳 ms）
  @override
  Set<Column> get primaryKey => {assetKey, dimension};
}
```

- `assetKey` 用**跨设备稳定身份** `sanitizeTtuFilename(book.title)`（`ttu_filename.dart`，与远端文件夹命名同源），**不用** `book.id`（每机不同，见 memory `book_identity_duplicate_import`）。
- `baseVersion` 对进度维度 = 上次同步成功后双方一致的时间戳（毫秒）。
- 表很小（每本书每维度一行），随书删除可做 GC（Phase 1 可暂不做 GC，留 TODO）。

迁移按 `hibiki_core` 既有 `onUpgrade` 逐版本增量风格新增建表语句；不触碰既有表。

### 3.2 三方判定（替换/包裹现有方向决策）

设本次同步该书进度维度：
- `local` = 本地 `ReaderPositions.updatedAt`（无本地位置则 null）
- `remote` = 远端进度文件时间戳 `parseProgressTimestamp(...)`（无远端文件则 null）
- `base` = `SyncBaselines` 查到的 `baseVersion`（无记录则 null）

判定表：

| 条件 | 结论 |
|---|---|
| `local == null && remote == null` | synced（无操作） |
| 仅一端为 null | 单边存在 → 按现有方向自动 import/export（**不冲突**） |
| `local == remote` | synced；顺手把 base 对齐到该值 |
| `local == base && remote != base` | 远端单边更新 → 自动 importFromTtu |
| `remote == base && local != base` | 本地单边更新 → 自动 exportToTtu |
| `local != base && remote != base && local != remote` | **真分叉 = 冲突** → 不自动解决 |
| `base == null && local != remote` | **老用户无基线兜底 → 当冲突**（见 3.3） |

> 关键：现有 `_determineSyncDirection` 只看 `local` vs `remote`。新逻辑在它之上引入 `base` 这第三个量，**单边改动的判定结果与今天完全一致**（向后兼容），只有「双边都偏离 base」这一新增分支会拦截成冲突。

### 3.3 老用户/首次无基线的兜底

历史安装没有任何 `SyncBaselines` 行。首次同步遇到 `base == null && local != remote`：

- **判为冲突**（安全：宁可问一次，也不静默覆盖）。
- 用户在冲突解决对话框选定方向后，按选定结果写入 base（= 胜出方的版本）。
- 若 `base == null` 且 `local == remote`：直接 synced 并把 base 写为该值（无打扰）。

这把「第一次」的代价限制为「真有差异时问一次」，之后基线建立，单边改动不再问。

### 3.4 基线写入时机（关键正确性点）

`baseVersion` 必须且只在**双方确实达成一致后**更新：

- import 成功（远端→本地）后：`base = remote 时间戳`。
- export 成功（本地→远端）后：`base = local 时间戳`（即写到远端文件名里的那个 ts）。
- `local == remote` 判 synced 后：`base = 该一致值`。
- **冲突被跳过时：绝不写 base**（保持「仍冲突」，下次/别处仍可检出）。
- 冲突经对话框解决并应用某方向后：按该方向的胜出版本写 base。

写 base 与写实际数据应在同一逻辑事务边界内尽量靠拢，避免「数据写了 base 没写」导致下次误判分叉。Phase 1 可接受「先写数据后写 base」的顺序（最坏是多问一次，不会丢数据）。

## 4. 自动同步：攒起来不打断（用户确认）

`_runAutoSync`（开/关书触发，可能正在阅读）遇到冲突维度：

- **跳过该书该维度**：不 import 不 export，不写 base，不弹任何模态。
- 其余非冲突书/维度照常自动同步。
- 冲突**不需要单独的持久队列**：任何时刻重算 `SyncBaselines` vs 当前 local/remote 即可得到「当前冲突集合」。

## 5. 冲突出口与解决 UI

### 5.1 复用 `SyncCompareDialog`

- 把 `SyncCompareEntry.hasConflict` 从「时间戳不等」**收紧为「基线真分叉」**：需要 `_fetchCompareData` 额外读取 `SyncBaselines.baseVersion`，并据 3.2 判定。
- 单边改动的项不再标记为 conflict（它们仍可显示为可同步项，但不进「冲突」分组）。
- 解决仍用现有 `useLocal` / `useRemote` 选择行 + Apply；Apply 后按 3.4 写 base。

### 5.2 入口

- **同步设置页**：新增「N 个冲突待解决」入口/角标（N = 当前重算出的冲突数）；点击打开 compare 对话框（可只筛冲突分组）。
- **立刻同步**：`_syncNow` 跑完 `runManualFullSync` 后，若报告含 `conflicts > 0` → 直接弹冲突解决对话框（compare 的冲突视图），而不是仅 SnackBar。

### 5.3 报告扩展

`SyncRunReport` / `ManualSyncResult` 增加 `conflicts`（被跳过的冲突项列表或计数），供 `_syncNow` 与设置页角标使用。

## 6. 有声书播放位置 — Phase 2（仅记录发现，不在本期实现）

调查发现有声书位置当前状态混乱，做冲突检测前必须先排查：

1. **存储 key 疑似错位**：真实播放位置由 `AudiobookRepository.updatePositionMs(bookUid, …)` 写 `audiobook_pos_<bookUid 字符串>`（`audiobook_repository.dart:99`）；而同步 `SyncRepository.setAudiobookPosition(bookId, …)` / `getAudiobookPosition` 写/读 `audiobook_pos_<bookId 整数>`（`sync_repository.dart:225-228`）。**同前缀、不同 key（字符串 uid vs 整数 id）**，意味着同步读写的很可能不是真实播放位置——疑似既有 bug，需按 `docs/BUGS.md` 流程验真伪。
2. **无本地时间戳**：本地位置只存一个 int，无 `updatedAt`，无法做三方基线。需新增位置更新时间戳（写在所有 `updatePositionMs` 调用点）。
3. **无独立同步方向**：有声书位置当前搭着阅读进度的方向走（在 `_handleImport`/`_handleExport` 内由 `syncAudioBook` 门控），没有独立的 `_determineSyncDirection`。要独立冲突检测须先解耦方向决策。

Phase 2 单独立项：先修 key 错位（如确为 bug）→ 加本地时间戳 → 解耦方向 → 套用本 spec 的 Phase 1 基线机制（`dimension = 'audiobook'`）。

## 7. 测试策略（最强可落地层）

- **纯函数三方判定**：把 3.2 的判定抽成纯函数 `resolveProgressSync({local, remote, base})` → `{direction | conflict}`，单测覆盖全判定表（含 base==null 兜底、同毫秒打平、单边 null）。这是核心，必须全分支覆盖。
- **基线写入时机**：单测验证 import/export/synced 后 base 被写成预期值；冲突跳过后 base **未**被改。
- **compare `hasConflict` 收紧**：扩 `sync_compare_delete_test.dart` 同套路，构造 base 使「单边改动不再是 conflict」「双边分叉才是 conflict」。
- **自动同步跳过冲突**：widget/单测验证 `_runAutoSync` 遇冲突不写数据、不写 base、不弹模态。
- **立刻同步弹冲突对话框**：widget 测试 `_syncNow` 在 `conflicts>0` 时弹出解决对话框（沿用 `tapDeleteAndConfirm` 风格的焦点驱动断言）。
- 迁移测试：v14→v15 建表 + 降级备份重建（`migration_test.dart` 既有套路）。

## 8. 向后兼容

- 单边改动的同步行为与今天**逐字节一致**（新增的只是 base 这第三个量上的「双边偏离」拦截分支）。
- 统计、书籍/词典资产同步完全不动。
- 老用户首次最多对「真有差异的书」各问一次，之后建立基线不再问。
- 新表只增不改既有表；降级走既有自动备份重建。

## 9. 风险与开放问题

- **base 与数据写入的原子性**：当前 Drift 调用非单事务；采用「先数据后 base」顺序，最坏多问一次，不丢数据（可接受）。若要更严格可后续包事务。
- **assetKey 选择**：用 `sanitizeTtuFilename(title)`；同名书（导入加后缀 `(2)`）由既有去重逻辑保证标题唯一，故 key 唯一。需在实现时确认 sync 路径拿到的 book 标题与远端文件夹命名同源。
- **冲突项的「版本」展示**：compare 对话框需展示两边的时间/进度供用户判断，现有 `_dataColumn` 已展示，确认信息足够。
- GC：删书后 `SyncBaselines` 残留行，Phase 1 留 TODO（不影响正确性，只占微量空间）。

## 10. 实现顺序（供 writing-plans 细化）

1. `hibiki_core`：加 `SyncBaselines` 表 + v15 迁移 + CRUD（get/upsert/deleteForAsset）。
2. 抽纯函数 `resolveProgressSync` + 全分支单测。
3. `SyncManager`：进度方向决策接入 base（读 base → 判定 → 写 base），冲突时返回新的 `SyncResult.conflict`（或在 `SyncBookResult` 加 `conflict` 标记）。
4. `SyncOrchestrator` / `runManualFullSync`：汇总 conflicts 进 `SyncRunReport` / `ManualSyncResult`。
5. `_runAutoSync`：冲突跳过、不写 base、不弹。
6. `SyncCompareDialog`：`hasConflict` 收紧读 base；Apply 后写 base。
7. 设置页冲突入口/角标 + `_syncNow` 冲突弹窗。
8. i18n（用 `tool/i18n_sync.dart`，禁手改 17 文件）。
9. 全套测试 + `dart format` + `flutter test`。
