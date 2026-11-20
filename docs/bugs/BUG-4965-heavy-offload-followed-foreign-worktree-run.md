## BUG-4965 · heavy.dart 排队时「另一台机器接走」后跟随了别的工作区的 dist 运行，报出不属于本工作区的 PASSED
- **报告**：2026-11-21（Claude 执行拍板台 pr3569 时发现）
- **真实性**：✅ 实测伪绿。在 `.worktrees/dec-pr3569/fushi` 下跑 `dart tool/heavy.dart -- flutter test <5 个定向测试> --no-pub`，排队期间打印 `heavy: another machine took … while it queued here; following that run`，随后输出的 dist 日志目录是 `.worktrees/dec-pr3605/.codex-test/dist/20261121-031720-3441`，快照 `9ca30a0904148485ab2f70d04981534e65c13498` 里没有本工作区的改动（`ambient_ticker.dart` 无 `_throttle`），批次里跑的是 `test/lookup/global_lookup_hotkey_guard_test.dart` 等别的文件，只 14 个测试，`DIST TEST VERDICT: PASSED`、退出码 0。同一组测试用 `--here` 本地跑实际 62 个、首轮还有真红。根因未定位（嫌疑：`tool/heavy.dart:341` 的 `asking!.taken!` 拿到的 `_DistAttempt` 与 offload claim 的归属；`_OffloadTarget.appDir` 指向了别的工作区）。
- **[ ] ① 未修复** — 临时规避：定向测试加 `--here` 本地跑，或核对输出里的 logs 路径与快照是否属于本工作区。
- **[ ] ② 未加自动化测试** —
- **备注**：
