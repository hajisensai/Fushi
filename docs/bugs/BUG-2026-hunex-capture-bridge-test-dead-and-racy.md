## BUG-2026 · hunex_gge_capture_bridge_test 的 79 条 assert 在 Release 下空跑，唤醒后 TestWorkerNeverReadsATornSnapshot 50% 概率红
- **报告**：2026-09-02（合并 PR#1116 时，被 BUG-2025 新接入的 assert 存活守卫抓出）
- **真实性**：✅ 真 bug，两层叠着：
  - **外层（与 BUG-2025 同族）**：`native/galgame_hook/tests/hunex_gge_capture_bridge_test.cpp:1` 首行直接 include，缺 `#undef NDEBUG`。CI 走 `--config Release`，MSVC 定义 NDEBUG，裸 `assert()` 被整条编译掉——本文件 79 条断言从未执行过。
  - **内层（被外层掩盖的真失败）**：补上 `#undef NDEBUG` 让断言活过来后，`TestWorkerNeverReadsATornSnapshot` 立刻在 `:248 assert(stable_reads != 0u)` 崩。
- **内层根因**：`stable_reads` 是读者（主线程）在与写者线程赛跑时攒的计数，而读者循环的退出条件是写者的 `writer_done`。写者跑固定 300 代就收工；seqlock 在写者满负荷时会持续把读者顶回去，读者常常一次稳定读都没拿到就撞上 `writer_done`。**判据本身是掷骰子**，不是产品缺陷——`ReadLatest` 在写者 join 之后照常成功（`:245` 那条断言是过的）。
- **实测**（MSVC 19.x `/utf-8 /EHsc /std:c++17 /O2 /DNDEBUG`，与 CI 的 Release 等价）：
  - 插桩打印 `stable_reads`，8 次运行取值 `46 / 1 / 0 / 11 / 1 / 1 / 0 / 1` —— 0 出现 2 次。
  - 直接跑断言版本：**30 次里红 15 次（50%）**。
  - 修复后同样 30 次：**0 次红**。
- **[x] ① 已修复** — 不放宽断言、不加重试/延时，而是把「读者到底读到没有」从竞态变量变成**写者的终止条件**：`stable_reads` 提升为 `std::atomic<size_t>` 并移到线程创建之前，写者的 for 条件改成「跑满 300 代**且**读者已攒够 `kMinStableReads = 8` 次」才退出（带 `kMaxGenerations = 200000` 硬上界防挂死）。写者不满足这个条件就不会置 `writer_done`，因此读者攒够 8 次未撕裂快照是必然事件，循环体里那一整圈逐字段校验也就真正跑过了。
  同时补上 `#undef NDEBUG` 头（置于任何 include 之前），让这 79 条断言真正生效。
- **[x] ② 已加自动化测试** — 由 BUG-2025 落地的 `tests/assert_liveness_guard_test.py`（已接入 `tools/run_guards.ps1`）负责挡「新原生测试忘了 `#undef NDEBUG`」这一族；本 bug 正是该守卫接入后抓到的第一条。确定性由上面 30/30 的实测覆盖。
- **备注**：这条是 BUG-2025 的直接收益证明——守卫接进 CI 的当天就从一条在飞 PR 里挖出一个「写了 79 条断言、一条都没跑、其中一条本来就是红的」的测试。也提醒一件事：**断言死掉的测试不只是没保护，它还会把已经存在的失败一起藏起来**，唤醒时要按「唤醒后是否本来就红」单独验一遍，不能默认补个 `#undef` 就完事。