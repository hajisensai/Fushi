## BUG-2072 · 数据根迁移回滚：搬移途中抛错的 plan 从未进 done，已 rename 的顶层项随新根被删
- **报告**：2026-09-03（审查 PR #1180 时在真实代码路径上读出，非用户上报；**未复现**）
- **真实性**：✅ 真 bug（既有缺陷，**不是 PR #1180 引入**）。根因 `fushi/lib/src/storage/data_root_migrator.dart:312-316`：

```dart
for (final _MovePlan m in moves) {
  await _moveTree(m, progress, deferredSourceDeletions);
  done.add(m);            // ← 抛错时根本没进 done
}
```

  `done.add(m)` 在 `_moveTree` **返回之后**才执行。一个 plan 搬到**一半**抛错（`_moveTreeSelective`
  里任意一项 rename 的 `rethrow`、`_copyTreeVerified` 的字节校验失败、目标写失败……），
  这个 plan 就不在 `done` 里，`_rollbackMoves(done)`（`:307`）压根不会看它 ——
  已经 rename 走的顶层项（源已从旧根消失）**没有被搬回**。

  随后同一个 catch 里的 `_cleanupCreatedSubtrees(createdSubtrees)`（`:317-318`）
  把恒在列表里的 `newDocs`（`:299-302`）递归删掉（`:743` `delete(recursive: true)`）
  → 那些项**永久丢失**。与 BUG-2071 同形状、同后果，只是触发面不同：
  BUG-2071 是「plan 搬完了但 `deferredCopy` 让回滚跳过」，本条是「plan 没搬完所以根本没进账本」。

  注意这条**不需要**沙箱/权限特例：搬移阶段任何一次 rethrow 都能触发。

- **[ ] ① 未修复** — 不在 PR #1180 范围内（独立改动）。方向：账本记录的时机要早于风险动作 ——
  进循环就把 `m` 记进 `done`（或让 `_MovePlan` 自己持有「本次真正搬进去了哪些顶层项」并让
  `_rollbackMoves` 无条件遍历 `moves` 而不是 `done`）。`movedTopLevelNames` 已经是逐项账本，
  空列表回滚是 no-op，所以「无条件回滚全部 plan」是安全的，不需要 `done` 这个第二份状态。
  真正的简化是**删掉 `done`**：两份状态（`moves` + `done`）表达同一件事，而它们会不同步。
- **[ ] ② 未加自动化测试** — 需要「选择性 plan 搬到一半抛错」的用例：白名单 A 项 rename 成功、
  B 项抛非 fallback 类错误（如 errno 2）→ 断言 A 项已搬回旧根、新根子树被清、零数据丢失。
- **备注**：与 BUG-2071 是同一根因家族（回滚账本与搬移动作不同粒度/不同时机），应一起修。
