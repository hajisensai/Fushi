## BUG-5377 · dist 在 macOS worker 上跑完测试后留下孤儿 flutter_tester 进程
- **报告**：2026-11-24（BUG-5375 收尾时给 self-mac 升 Flutter 时发现）
- **真实性**：✅ 现场确认，根因未查。self-mac（192.168.1.34）上有 8 个 `flutter_tester`，父进程都是 1，已挂 1～17 天，命令行指向 `~/fushi-dist/work` / `work-2` 下的 dist 临时 `flutter_test_listener`（`.git/fushi-dist/tmp-*`），都是以前 dist 测试批次留下的。已在 2026-11-24 手动 `pkill` 清掉。
- **怀疑方向**：`fushi/tool/dist_test/worker_run.sh` / `worker_kill.sh` 在 macOS 上只结束直接子进程，没收整棵树（`worker_build.sh` 有 `kill_tree`，测试路径是否同样处理待核）；或者批次超时 / 被取消时 `flutter test` 被杀，留下的 tester 被 launchd 收养。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：孤儿会一直占着 Mac 的内存和 CPU，下一批外包测试会被拖慢。
