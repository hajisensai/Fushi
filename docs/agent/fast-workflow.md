# 分级快车道：加功能 / 修 bug / 合并的提速流程

目标：单功能或单 bug 从 ~30 分钟压到 **~10–15 分钟**。手段只有三个——**消灭空等、按难度分工、验证按爆炸半径分级**。本文件是 [CLAUDE.md](../../CLAUDE.md) 「多使用子代理」和「验证」条目的展开，不改变真机验收、发布通道、提交纪律等硬规则。

## 现状 30 分钟花在哪（耗时解剖）

| 阶段 | 现状耗时 | 浪费点 |
|---|---|---|
| worktree + full bootstrap | 3–5 min 串行阻塞 | 根因分析根本不需要 `.dart_tool`，却在干等 pub get |
| 定位 / 根因分析 | 5–10 min 串行 | 多个独立疑点逐个查 |
| 实现 | 5–10 min | 机械面（样板/测试/多文件同构改动）没拆出去 |
| 验证 | 8–15 min | 小改动也跑全量 `flutter test`，而 CI 本来就会兜底 |
| 收尾（bug 文档/commit/PR） | 2–3 min | 等测试跑完才开始写 |

## 三条军规

1. **永不空等**：任何 >30 秒的命令（bootstrap / test / gradle / build）一律后台跑，等待期间推进别的步骤。
2. **按难度分工**：琐碎活主代理直接干（派发开销 > 收益）；机械面拆给子代理并行；根因、数据结构、整合这些错了会返工的难点主代理亲自把关。绝不让两个代理重复做同一件事。
3. **验证按爆炸半径分级**：分支上定向验证 + PR CI 兜底全量；合入 `develop` 前才要求本地全量。

## 难度分级 × 分工

| 级别 | 判据 | 谁干 | 分支上的验证 |
|---|---|---|---|
| **S 琐碎** | 文档、注释、单行改动、纯重命名 | 主代理直接干，**不派子代理**（派发开销 > 收益） | `git diff --cached --check`；涉及 Dart 再加定向 analyze |
| **A 小修** | 单文件或单模块，根因明确 | 主代理修核心；测试可拆一个子代理并行写 | `flutter analyze` 全量 + 定向 `flutter test <目标> --no-pub` |
| **B 功能 / 复杂 bug** | 跨模块、多文件、时序/状态/平台边界问题 | 主代理定根因和数据结构；机械面（样板、i18n、多文件同构、测试）拆子代理并行 | 定向 + 相邻功能测试；全量交 PR CI |
| **C 大型 / 长周期** | 多阶段、需分批审查 | 按 claim 拆多 agent；integration owner 统一收口 | 本地全量（bash 环境） |

**子代理纪律**（既有规则，重申）：后台派发，主代理不空等回传；每个子代理给明确文件清单，避免撞同一脏文件；强顺序依赖的步骤别硬拆；子代理回传必须核关键证据（`git diff --stat` / `test -f` / grep），不可全信叙述。

## 标准时间线（B 级功能，目标 ~12 min）

```
t=0   EnterWorktree → setup_worktree -SkipBootstrap（秒级，只搬密钥）
t=0   ↳ 后台: powershell -File tool/bootstrap.ps1
t=0   ↳ 并行: 主代理读代码定根因；≥2 个独立疑点 → 子代理并行定位
t=3   根因确定 → 主代理写核心修改；同时子代理并行写测试/机械面
t=8   bootstrap 已就绪 → dart format 改动文件 + flutter analyze + 定向 test --no-pub
t=8   ↳ 测试跑的同时: 子代理建 bug 文档 (dart run tool/bug.dart new)，
      主代理写 commit message / PR 描述
t=12  测试绿 → commit → push → draft PR（CI 跑全量兜底）
```

S/A 级同理裁剪：S 级连 worktree bootstrap 都可 `-SkipBootstrap` 到底（纯文档不需要 pub get）；A 级只是没有并行实现面。

## 验证分级细则

- **定向测试** = 改动直接覆盖的 test 文件 + 相邻功能的 test 文件，`flutter test test/<路径> --no-pub`。
- **`flutter analyze` 全量在 push 前必跑**（含 test 目录）——它本身只要秒级~1 分钟，而 CI 把 warning 当致命，省这一步只会在 CI 上浪费一轮。
- **分支 draft PR**：定向测试绿 + 全量 analyze 绿即可 push；全量 test 由 CI 兜底（真单测门是 **Build Release APK 的 Run unit tests**，不是 Build and Test）。声明「修好了」的真机复测门槛**不变**（[integration-testing.md](integration-testing.md)）。
- **合入 `develop`**：integration owner 本地全量 analyze + 全量 test **不变**（bash 环境跑；别 `| tail` 吞退出码；重叠跑会互抢 `sqlite3.dll`，见下节）。

## 并发伪红判别

本机常态是 5~10 个 agent 同时跑测试，**测试红有相当比例不是被测代码坏了**。下面三类都是实测形态，各有独立的定性办法。

**遇红先分型，再动手**——断言失败 / suite 装载失败 / 零输出，三者的处置完全不同，串了型就是白追一轮。

| 形态 | 症状 | 定性办法 | 处置 |
|---|---|---|---|
| ① 互抢 `sqlite3.dll` | 多个 `flutter_tester` 争用同一份 native 库；无关文件莫名失败，或进程不报错只静停 | 数一下本机在跑的并发测试进程（`dart` / `flutter_tester`） | 别重叠跑；错开或串行化后单独重跑该目标确认 |
| ② 宿主 IPC 崩溃 | VERDICT `FAILED - ...(N 个 error event(s), M 个 tests completed)`，但**零断言失败**；日志里 `Bad state: Cannot close sink while adding stream.` @ `flutter_tools/flutter_platform.dart:766` → `Connection closed before test suite loaded` | 本质是 suite **装载**失败，不是断言失败。**分片重跑并对账**：各分片完成数之和 ≈ 原批完成数 + 没装载上的数量 | 账对得上 → 伪红，按分片结果判绿，并在回报里写清对账数字 |
| ③ 结果文件被抢 | 跑很久**零输出、像卡死**；既没断言失败也没装载失败 | 看有没有并发进程在写同一份 `.codex-test/flutter-test/flutter_test.jsonl`（`flutter_test_failures.dart` 的默认输出目录就是 `../.codex-test/flutter-test`，所有 agent 共用） | **规避优先于诊断**：每次跑都显式给独立输出，`--output-dir=../.codex-test/flutter-test-<任务名>` |

出处：② PR#716 实测（7 路并发 / 27 个 dart+flutter_tester 进程；分片对账 325 + 2602 = 2927 ≈ 2923 完成 + 4 个没装载上）；③ PR#728 实测。

### 判别纪律（三条，不可打折）

1. **先分型再动手**：先看是断言失败、suite 装载失败还是零输出。只有断言失败才是「被测代码可能坏了」，另两类先按并发伪红查。
2. 🔴 **不许拿「可能是并发伪红」当借口跳过真红**。伪红是要**证明**出来的（进程数、分片对账、并发结果文件），不是默认假设。判不明就如实写一句「这条红我没判明，交给 CI」并继续推进——**不要反复重跑碰运气，也不要默认它是假的**。
3. 🔴 **零测试执行的红也不算红**。变异测试里删掉整行造成编译失败、`0 tests ran` 的，那不是行为红，是**无效变异**，必须把变异改成能编译的形态再跑。这与「零测试执行的绿是假绿」（BUG-1157）是同一枚硬币的两面：**`N tests ran` 的 N 本身就是判据的一部分**，N=0 时 PASSED 和 FAILED 都不成立。

## 合并流水线（integration owner）

落地范式不变：干净 worktree ff → merge → 解 i18n → analyze → bump。提速点：

- 全量 test 在后台跑的**同时**，预解下一个 PR 的冲突和 i18n（流水线化，不是并行 merge）。
- 多 PR 逐个 **rebase 叠加**，不做旧基底 merge——旧基底 merge 会静默删掉先落地 PR 的文件（并发合并竞态）。
- 合并后核对以独立 `git diff --stat` 为准，不信子代理叙述。

## 空等浪费禁止清单

- ❌ 前台跑 bootstrap / 全量 test / gradle 并盯着输出——一律后台，期间推进其它步骤。
- ❌ 同一疑点串行试三轮 grep——派一个搜索子代理一次扫完拿结论。
- ❌ 测试跑完才开始写 bug 文档 / PR 描述。
- ❌ 只为读几个文件就新建 worktree + full bootstrap——**只读/分析不需要 worktree**，直接在原工作区读。
- ❌ 同一子任务派两个子代理各做一遍「互相印证」——要印证就派**不同角度**（如实现 vs 反驳审查），不是重复劳动。
