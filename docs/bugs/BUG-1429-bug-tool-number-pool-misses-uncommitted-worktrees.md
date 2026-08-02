## BUG-1429 · bug.dart 取号扫不到并发工作区未提交的 bug 文件，一天连撞六次
- **报告**：2026-08-02（用户：）
- **真实性**：✅ 真 bug。根因 `tool/bug.dart:470-496`（改造前的 `bugNumbersInTrees`，
  只读 `<ref>:docs/bugs` 的 **commit 树**）。
  `bug.dart new` 是**先写磁盘文件**、几十分钟到几小时后才 commit（要先定位根因、改代码、
  跑测试），这整段窗口对并发 agent 完全不可见，而并发 agent 恰恰就在这段窗口里取号。
  本会话六次撞号（1412→1413、1415→1416、1416→1417、PR#716 的 1418、PR#719 的 1419、
  PR#720 的 1419/1420）全部落在这个窗口里。
  **现场 A/B 证据**（2026-08-02，本机 1804 个 ref / 693 个工作区）：
  ```
  旧口径（只扫 1804 个 ref 的 commit 树）：已占最大 = 1426 → 会取 1427
  新口径（+ 693 个工作区磁盘文件）：已占最大 = 1427 → 会取 1428
  旧口径完全看不见的号（盲区）：[1427]
  BUG-1427 已被 1 个不同文件名占用：
        BUG-1427-zero-context-patch-drift-silent.md ← 工作区 .../worktrees/agent-a39aafd3d44210dd0
  ```
  也就是说：不修的话，本条 bug 自己取号时就会撞成第七次。
  次要盲区两处：① ref 上 bug 文件的**正文 H2 号**没算（文件名与 H2 不一致时漏一个号）；
  ② 输出只给一个「跨 N 个分支最大 M」的裸数字，被读成「M 没冲突」（实际 M 已被占）。
- **[x] ① 已修复** — `tool/bug.dart`：号池新增「本机每个 git 工作区磁盘上的
  `docs/bugs/*.md`」这条数据源（`gitWorktreePaths` / `collectWorktreeBugNumbers`），
  把 TOCTOU 窗口从小时级压到同一次扫描内的毫秒级；ref 侧改成按结构解析 tree 项
  （`parseTreeEntries`，不再在二进制里瞎正则），并按 blob sha 去重读一遍正文 H2；
  输出全部改成显式「已占」口径；`check` 新增跨分支/工作区占用复核（`--strict` 可当硬门）。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/bug_tool_number_pool_test.dart`
  （新增两组共 10 个用例：未提交工作区必须算已占 / 降级时仍看得见本机工作区 /
  ref 上的 H2 号算已占 / 代码引用不算认领 / `check` 报占用与来源 / base 已定案的号不报噪声 /
  `--strict` 退非 0 / tree 与 batch 的结构化解析）。
- **备注**：不是分布式锁——两个 agent 在同一次扫描期间各自落盘仍会撞；跨机器未 push 的号
  也看不见。开 PR 前和每次 rebase 后仍要重跑 `dart run tool/bug.dart check`。
