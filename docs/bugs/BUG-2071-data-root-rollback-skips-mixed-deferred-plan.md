## BUG-2071 · 数据根迁移回滚：混合 rename+copy 的选择性 plan 被整条跳过，已 rename 的顶层项随新根被删
- **报告**：2026-09-03（审查 PR #1180 时在真实代码路径上读出，非用户上报；**未复现**——需要在 macOS 沙箱下真的让部分顶层项 rename 拿到 EPERM/EACCES/ETIMEDOUT）
- **真实性**：✅ 真 bug（既有缺陷，**不是 PR #1180 引入**；PR #1180 只是让 macOS 上 errno 60 更容易走到这条 copy 回退路径，从而更容易踩到它）。根因 `fushi/lib/src/storage/data_root_migrator.dart:653-660`：

```dart
for (final _MovePlan m in done.reversed) {
  if (m.deferredCopy) {
    continue;                    // ← 整个 plan 跳过回滚
  }
  if (m.isSelective) { await _rollbackSelective(m); continue; }
  ...
```

  `deferredCopy` 是 **plan 级的单个 bool**，但选择性 plan（`data_root.part.dart:268-269`
  的共享 `~/Documents` 白名单 → `documentsTopLevelIncludeNames` 非 null → `_MovePlan.isSelective`）
  的顶层项是**逐个**搬的（`data_root_migrator.dart:513-538`）：
  - 一部分同盘 `rename` 成功 → 记进 `plan.movedTopLevelNames`，**源已经从旧根消失**；
  - 另一部分 rename 失败走 copy → `plan.deferredCopy = true`，源保留在旧根。

  只要出现**混合**状态，`continue` 就让整个 plan 跳过 `_rollbackSelective`，
  已经 rename 走的那些顶层项**没有被搬回旧根**。随后 `migrate` 的 catch 调
  `_cleanupCreatedSubtrees(createdSubtrees)`（`:317-318`），而 `createdSubtrees`
  **恒含 `newDocs`**（`:299-302`，无条件项），`_cleanupCreatedSubtrees` → `_deleteIfPresent`
  → `delete(recursive: true)`（`:743`）把新根 documents 子树整个递归删掉
  → 那些已 rename 的顶层项（`fushi_books` 等 Hibiki 自有数据）**永久丢失**。

  `continue` 分支的注释（`:654-658`）写的不变量是「跨盘复制且源尚未删除 ⇒ 源在旧根完好无损」——
  这个前提对**整目录**搬移成立，对**逐项**搬移的选择性 plan 不成立。判据的粒度（plan 级 bool）
  比事实的粒度（顶层项级）粗一层，这是根因。

- **[ ] ① 未修复** — 不在 PR #1180 范围内（独立改动，需单独 PR + 单独回归测试）。方向：把 `deferredCopy`
  从 plan 级 bool 降到顶层项级（例如让 `_rollbackSelective` 只搬回 `movedTopLevelNames`、
  而 `deferredCopy` 只用来决定「这些项的源要不要删」），让回滚判据与搬移判据同粒度；
  别用「选择性 plan 就不许混合」之类的特例分支绕过。
- **[ ] ② 未加自动化测试** — 需要一个「白名单里 A 项 rename 成功、B 项 rename 抛 EPERM 走 copy、
  随后 commit 阶段抛错」的用例，断言 A 项回到旧根、新根子树被清、零数据丢失。
  `DataRootMigrator.debugForceCopyFallback` 是全局开关（全部项都走 copy），造不出混合态，需要更细的注入点。
- **备注**：与 BUG-2072 是同一形状（回滚的账本粒度比搬移粗）的两个不同触发面，应一起修。
