## BUG-3558 · 测试：真跑 node / Chrome 的测试缺运行时时行为不一致，srs_card_design_skin_test 在 CI 上缺依赖静默跳过
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真问题。根因：仓库无统一约定（约 112 个 node 测试里 39 个缺 node 跳过，多数 `markTestSkipped` 后 return 照常算通过），`fushi/test/srs/srs_card_design_skin_test.dart:222`（修前）缺 node / Chrome 时 `markTestSkipped` 静默绿，`srs_card_autoplay_gate_test.dart` 则直接红。CI unit-tests（`.github/workflows/main.yml:402`，ubuntu-24.04）跑整个 test/，镜像自带 node。
- **[x] ① 已修复** — 新增共用 `fushi/test/helpers/node_runtime.dart`（`NodeTestRuntime.probe`）：本地缺 node / Chrome 用 `test(skip:)` 明确跳过并写原因；CI（`CI=true` / `GITHUB_ACTIONS=true`）缺依赖一律失败。两个 SRS 卡面 node 测试改用它。
- **[x] ② 已加自动化测试** — 实测：PATH 去掉 node 本地跑两文件 → 退出码 0，10 过 7 跳过（原因 node not found on PATH）；同条件 `CI=true` → 退出码 1，7 条失败。
- **备注**：其余存量 node 测试仍各自为政，逐步迁到该 helper（本次只改 SRS 两个）。
