## BUG-2851 · 排行榜「账户已在别处删除」用例按固定轮数等真 IO，CI 忙时偶发红
- **报告**：2026-10-01（用户：「现在 action 不少流水线跑红了，看看什么情况修复一下」）
- **真实性**：✅ 真问题（测试时序依赖）。develop run 36830851605（`6480fe130`）`tests (2)` 红在
  `fushi/test/leaderboard_ui/leaderboard_ui_test.dart:1390`「账户已在别处删除：榜单请求 401 后自动回到说明页并提示原因」：
  `Expected: LeaderboardStatus.disabled / Actual: LeaderboardStatus.active`。状态要变成 disabled，得先走完
  401 → `_onAccountGone`（`fushi/lib/src/leaderboard/leaderboard_service.dart:567`）→ `_clearLocal`（550–561）排进串行写队列
  → `store.delete()` 的**真实磁盘 IO** → 清空 `_account`；用例只调两次固定 10 轮的 `settle()`，不等 IO 完成，CI 忙时就先断言了。
  同文件已有为这种情况写的 `settleIo`（按条件转、上限 300 轮），这个用例没用。之后的 develop run 变绿只是没撞上，没有提交修过它。
- **[x] ① 已修复** —— 该用例改为 `settleIo(tester, () => service.status == LeaderboardStatus.disabled)` 再补一帧 `pump`
  （按条件等，到上限仍不成立交给后面的 expect 如实报错，不是加延迟掩盖）。
- **[x] ② 已加自动化测试** —— 修的就是测试本身：`fushi/test/leaderboard_ui/leaderboard_ui_test.dart` 整文件 28 条本机通过。
- **备注**：同类写法另见 BUG-2801（排行榜 401 竞态，PR #1804）。
