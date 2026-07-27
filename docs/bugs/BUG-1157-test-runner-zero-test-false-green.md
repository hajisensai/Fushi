## BUG-1157 · 全量测试入口把「零测试执行」当成通过（native asset 构建失败被伪装成绿）

- **报告**：2026-07-27（用户：hajisensai）
- **真实性**：✅ 真 bug（已本机复现两条独立路径）

### 复现

新建 worktree 首跑测试时，`pdfium_dart` 的 build hook 需要从 GitHub 下 `pdfium-*.tgz`；下不到就抛异常，
`flutter test` 打印 `Building native assets failed. See the logs for more details.` 且**一个测试都没跑**。

本机把 `pdfium_dart-0.2.5/hook/build.dart` 临时改成直接抛异常复现：

| 调用方式 | 退出码 | 结论 |
|---|---|---|
| `flutter test <file> --no-pub` | `1` | flutter 工具本身是对的 |
| `flutter test <file> --no-pub 2>&1 \| tail -3` | **`0`** | 管道吃掉退出码，零测试伪装成绿 |

### 根因（两层，都不在 flutter 工具里）

1. **shell 层**：`flutter test ... | tail -N` 的退出码是 `tail` 的，恒为 0。
   `flutter test` 失败时输出里**没有任何 `All tests passed`**，但也没有「FAILED」这类末行判据，
   只看退出码或只看尾部若干行的人/agent 一律判成绿。
2. **仓库自己的测试入口层（可机器修的真根因）**：
   `hibiki/tool/test_flow/flutter_test_failure_filter.dart:12`（修前）
   ```dart
   bool get hasFailures => success == false || errors.isNotEmpty;
   ```
   - 从没解析过 `testStart` / `testDone` 计数：**跑了 0 个测试也算过**；
   - `success == null`（reporter 根本没发 `done` 事件，正是构建失败的形态）被当成**通过**；
   - `hibiki/tool/flutter_test_failures.dart:43-48`（修前）把子进程 stderr 只在 `--verbose-output` 时转发，
     native asset / 编译失败的全部诊断被静默吞进文件，失败现场看起来是「安静的成功」。
   这条路径正是 CI 真单测门（`Build Release APK` → `Run unit tests`）跑的东西。
   同类问题还有 `hibiki/tool/test_flow/comprehensive_test_reporter.dart:57`：
   `entries` 为空（一个场景都没执行）时 `hasFailures == false` → 运行器 exit 0。

### 修复

- **[x] ① 已修复** — commit 见下
  - `hibiki/tool/test_flow/flutter_test_failure_filter.dart`
    - 解析 `testDone` 并统计非 hidden 的完成测试数（`loading …` / `compiling …` 合成测试不计数）；
    - 新增 `FlutterTestRunSummary.failureReason({minimumTests})`：`success == null`、`success == false`、
      有 error 事件、或完成测试数 < `minimumTests` 一律返回失败原因；
    - 新增唯一判定入口 `resolveFlutterTestVerdictFailure({flutterExitCode, summary, minimumTests})`
      和末行判据常量 `kFlutterTestVerdictPrefix`。
  - `hibiki/tool/flutter_test_failures.dart`
    - 判定统一走 `resolveFlutterTestVerdictFailure`，失败 exit 非零（子进程非零就透传其码，否则 1）；
    - **无条件转发子进程 stderr**（构建失败诊断不再被吞）；
    - 结尾在 **stdout** 打一行 `FLUTTER TEST VERDICT: PASSED - N tests ran…` /
      `FLUTTER TEST VERDICT: FAILED - …`，让 `| tail` 这类丢退出码的管道也拦得住；
    - 新增 `--min-tests=N`（默认 1），需要时可钉基线量级。
  - `hibiki/tool/test_flow/comprehensive_test_reporter.dart` / `hibiki/tool/comprehensive_test_runner.dart`
    - 空报告（零场景执行）计为失败并打印明确原因。

- **[x] ② 已加自动化测试**
  - `hibiki/test/tools/flutter_test_failure_filter_test.dart` — group「zero-test runs must never look green (BUG-1157)」：
    无 `done` 事件、`done:success` 但 0 测试、hidden `loading` 测试不计数、真通过为绿、
    子进程非零必失败、`minimumTests` 基线。
  - `hibiki/test/tools/flutter_test_failure_workflow_guard_test.dart` — 源码守卫：入口必须走
    `resolveFlutterTestVerdictFailure`、必须打 PASSED/FAILED 末行判据、stderr 转发不得再被 `verboseOutput` 条件化、
    不得存在绕过判定的无条件 "Flutter tests passed"。
  - `hibiki/test/integration/comprehensive_test_matrix_test.dart` — 空 `ComprehensiveReport` 必须 `hasFailures == true`。

### 负向验证（人为制造失败）

临时把 `pdfium_dart` hook 改成直接抛异常后：

| 场景 | 退出码 | 末行 |
|---|---|---|
| `dart run tool/flutter_test_failures.dart …`（hook 抛异常，`dart run` 自己也要跑 hook） | `255` | `Error: Running build hooks failed.` |
| 入口 + 子进程直接夭折（无任何 JSON） | `64` | `FLUTTER TEST VERDICT: FAILED - flutter test exited with 64. The Flutter test harness never reported a result (no "done" event)…` |
| 入口 + 子进程 exit 0 但零测试 | `79` | `FLUTTER TEST VERDICT: FAILED - … Only 0 test(s) ran, expected at least 1.` |

三种都经 `2>&1 | tail -3` 复核：`FLUTTER TEST VERDICT: FAILED` 始终是最后一行。验证后已还原 pub-cache hook。

### 备注

- CI 侧真单测门 `Build Release APK` → `Run unit tests` 用 `run:` 直调、无管道，native asset 失败会让
  `dart run` 本身 255 退出 → 红，**没有** 本 bug 的退出码丢失形态；但修前它有「零测试也算过」的形态（tag 过滤漂移等），本次一并堵上。
- `release.yml` 的 `tests` job 与 `build` job 无 `needs:`（TODO-fast-release 的**有意**解耦），
  `build-multiplatform.yml` android job 的 `continue-on-error: true`（模拟器 boot flake，TODO-624）也是**有意**的，
  两者都不属本 bug，未改动。
