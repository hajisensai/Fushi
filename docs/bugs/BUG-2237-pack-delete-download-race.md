## BUG-2237 · 推荐包清理与续传缺少互斥
- **报告**：2026-09-07（PR #1276 审查）
- **真实性**：✅ 真 bug。原 `recommended_pack_download_controller.dart:280` 仅在异步删除前检查 paused，删除期间 start 可进入，删除收尾再覆盖下载状态。
- **[x] ① 已修复** — 删除、启动与启动清理共用任务互斥；删除进行中禁用 UI 操作。修复提交：`85ffd5fbb3`。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/recommended_pack_deletion_test.dart`：可控删除 Future 验证删除时拒绝启动、重复删除和清理，并验证结束后可再次下载。
- **备注**：网络替身不下载真实推荐包；设备验证证据另记 PR。
