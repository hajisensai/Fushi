## BUG-5239 · heavy.dart 排队预测不计轻槽持有者的内存，误判「等不完」提前 exit 75
- **报告**：2026-11-22（审查 HBK-AUDIT-224，`docs/reviews/2026-11-22-project-review.md`，起因 PR #4115）
- **真实性**：✅ 真 bug。`fushi/tool/test_flow/heavy_lease.dart` 原 `_hopelessWait`（develop `283a920286` 的 `:675`–`:709`）先把持有者过滤成 `h.slot < slots`（丢掉 analyze 的轻槽持有者），再拿这份过滤后的列表判「前面的等待者现在放不放得进内存预算」；真实准入 `_admit` 与 `heavyMayGoAhead` 用的是全部持有者（轻槽也订预算）。于是轻槽占着内存时，预测把其实放不进预算、本轮会被插队越过的等待者算进前面，预测 20 分钟而真实 1 分钟就能准入，`--wait-max-min` 下立即 exit 75。预测还在准入锁外另读一次队列与内存，和准入判的不是同一份快照。
- **[x] ① 已修复** — 预测改成纯函数 `heavyQueuedWait`（`fushi/tool/test_flow/heavy_wait_estimate.dart`）：只有常规槽持有者会释放槽，所有持有者（含轻槽）都订预算，和准入同一口径。`_admit` 返回它在准入锁下看到的 `_AdmissionView`（槽数、预算、全部持有者、队列），`_waitSlot` 拿这份快照做预测，不再二次读队列 / 内存。
- **[x] ② 已增加自动化测试** — `fushi/test/tools/heavy_wait_estimate_test.dart` `heavyQueuedWait` 组：模拟时钟下两个常规槽持有者 + 一个轻槽持有者 + 两个排在前面的等待者，预测 1 分钟（旧口径得 21 分钟）；去掉轻槽持有者时两个等待者放得进预算、按序计入得 21 分钟；轻槽持有者不释放常规槽。
- **备注**：
