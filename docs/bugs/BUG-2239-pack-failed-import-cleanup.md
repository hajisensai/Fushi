## BUG-2239 · 推荐包导入失败后仍被启动清理删除
- **报告**：2026-09-07（推荐包完整链路审查，非 PR #1276 新引入）
- **真实性**：✅ 真 bug。原 `sync_settings_schema/backup.part.dart:986` 在恢复前触发 onImportConfirmed 写标记；后续失败不撤销，启动 `cleanupIfImported` 仍删除下载包。
- **[x] ① 已修复** — 回调改为恢复成功后触发；清理只认 `completed` 凭据，旧版 `1` 标记不再作为成功证明。成功后的教程待办存于包目录和恢复数据库之外。修复提交：`85ffd5fbb3`。
- **[x] ② 已加自动化测试** — `recommended_pack_cleanup_test.dart` 验证成功清理、失败/旧标记保留及恢复到回调的执行顺序；`recommended_pack_tutorial_state_test.dart` 验证重启、跳过、完成和包清理后的提醒状态。
- **备注**：不对用户真实数据库执行破坏性故障注入；真实恢复/重启设备覆盖情况见 PR。
