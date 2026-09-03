## BUG-2016 · develop 上 galgame 守卫门长期红：engine-support.yaml 缺逗号 + dll_main 行数棘轮被 include 顶破
- **报告**：2026-09-01（审查 PR 队列时发现，非用户报告）
- **真实性**：✅ 真 bug。`native-galgame-gate` workflow 存在且在 PR 上真跑（`.github/workflows/native-galgame-gate.yml` -> `native/galgame_hook/tools/run_guards.ps1`），但 develop 自 2026-08-30 起在它上面一直是红的，两条独立失败：
  - **①** `native/galgame_hook/engine-support.yaml:2383` 行尾缺逗号，flow sequence 里出现两个相邻标量 -> `generate_engine_support.py --check` 与 `engine_support_manifest_test.py`（21 条）全错。由 `2d81155c64`（SGRE 家族识别，BUG-1950）带入。
  - **②** `native/galgame_hook/tests/adapter_structure_test.py:60` 的行数棘轮 `assertLess(source.count("
"), 720)` 被 `hook/dll_main.cpp` 的 721 行顶破。越界的两行是 `f6fdee0831` 那次 merge 加的 `#include "module_settle.h"` 与 `#include "host_executable_digest.h"`。
- **为什么门在却没拦住**：门确实红了 —— `gh run list --workflow=native-galgame-gate.yml` 显示 `codex/gal-lookup-no-ocr` 在 2026-08-30T15:10 是 `completed/failure`，**那条 PR 带着红被合进了 develop**（develop 无分支保护，该 check 非必需）。这不是覆盖缺口，是「红被无视」。
- **[x] ① 已修复** — ①补回缺失逗号；②把行数棘轮从「数总行数」改成「只量代码行」（剔块/行注释、去空行、去 `#include`），阈值 520，当前实测 460。守卫自陈行数预算只是代理判据、真正判据是随后三条（必须经 registry、不得出现 `TryHook`），且上界此前已因 include 与注释从 700 抬到 720 —— 再抬一次只是让阈值跟着噪声漂，真正要挡的引擎逻辑反而获得越来越大的余地。改判据而不是改数字。
- **[x] ② 已加自动化测试** — 判据本身即测试（`tests/adapter_structure_test.py::test_main_worker_only_uses_registry`）。双向变异实测：
  - 正向：向 `dll_main.cpp` 注入 60 行代码 -> `AssertionError: 520 not less than 520`，真红。
  - 反向：注入 30 行 `#include` + 30 行注释（总行数 721 -> 783，**旧守卫在此必然误报**）-> 新守卫保持绿，证明改动在两个方向上都有意义。
  - 两次均按唯一标记还原（未用 `git checkout`），`sha256 = bba619ee826319694b18c485be7a6d28dea620721eb96ccd26ec70960e5bdb6f` 逐字节核回基线。
- **备注**：修复后 `run_guards.ps1` 整套退出码 0（`All galgame_hook source-of-truth guards passed.`）。注意 PR #1116 / #1119（均为 `W1ght/hibiki` 的跨仓库 PR）各自也顺手盖过了这两条，与本修复会有小冲突；本条的价值在于不等那两条落地就先把 develop 恢复绿。
