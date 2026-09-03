## BUG-2025 · generic_input_shield_test.cpp 的 47 条 assert 在 Release 下整批空跑（守卫写了但没接进 run_guards.ps1）
- **报告**：2026-09-02（用户：合并 PR#1116 前跑 galgame native 守卫整批时撞出）
- **真实性**：✅ 真 bug。两层根因：
  - `native/galgame_hook/tests/generic_input_shield_test.cpp:1` 首行直接 `#include "generic_input_shield.h"`，全文件缺 `#undef NDEBUG`。CI 用 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 `assert()` 被整条编译掉——文件里 47 条断言全部不执行，测试恒绿。与 BUG-1157「零测试执行伪装成通过」同族。
  - `native/galgame_hook/tools/run_guards.ps1:68-74` 是人工维护的清单，`tests/assert_liveness_guard_test.py`（正是为了挡上一条而写的守卫）**从来没被登记进去**。8 个 `tests/*_test.py` 里它是唯一失联的一个，因此只有手动 `python -m unittest discover` 才会跑到，任何 CI 入口都执行不到它。
- **实测证据**（MSVC 19.x，`/O2 /DNDEBUG`，与 CI 的 Release 等价）：
  - 把 `assert(eligible == (kKey | kRawBuffer))` 变异成必假的 `assert(eligible == 0xDEADu)`：
    - 带 `#undef NDEBUG` → `Assertion failed ... line 217`，退出码 `-1073740791`。
    - 去掉 `#undef NDEBUG`、同一条必假断言 → **退出码 0，静默通过**。
  - 修复后原样真编真跑 → 退出码 0，47 条断言全部真实成立（没有隐藏的真失败）。
- **引入点**：`b7b9796110`（feat(galgame): add no-OCR attached lookup geometry v19，经 `codex/gal-lookup-no-ocr` 合入 develop）。该分支上 `native-galgame-gate` 的 run 33318886762 结论就是 `failure`，PR 仍被合入；`native-galgame-gate.yml` 只在 `pull_request` 触发，develop 上一次都没跑过，所以这条红进主干后无人可见。
- **[x] ① 已修复** — 三处：
  1. `tests/generic_input_shield_test.cpp` 头部补 `#undef NDEBUG`（置于任何 include 之前）。
  2. `tools/run_guards.ps1` 登记 `tests/assert_liveness_guard_test.py`。
  3. 根治清单漂移：`tests/galhook_workflow_test.py` 新增 `GuardRegistryTest`，用目录枚举 `tests/*_test.py` 核对每一条都出现在 `run_guards.ps1` 里。新增守卫自动进入扫描面，不再依赖任何人记得同步第二处。
- **[x] ② 已加自动化测试** — `tests/galhook_workflow_test.py::GuardRegistryTest::test_every_python_guard_is_registered_in_run_guards`。变异实测：删掉 `run_guards.ps1` 里那行登记 → 该用例红（`- ['assert_liveness_guard_test.py'] / + []`）；按唯一锚点还原后 sha256 与变异前逐位一致。整批 `python -m unittest discover -s tests` 273 条绿。
- **备注**：这是「守卫存在但没有任何入口执行它」这一族的第一条记录。它与「新增设置项漏登记 `kCoveredElsewhere`」「新增列漏登记 `kPathRebaseColumns`」同形：**人工名单 + 新增文件 = 静默失效**，唯一稳的办法是把名单换成目录枚举。