## BUG-3242 · 重新提交带原截图时单张取回失败不提示
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_compose_page.dart` `_toggleParentShots`（原 :303-314）逐张取原截图，单张失败只 `ErrorLogService.log`、不计数也不提示：开关显示「已带上原截图」，附件里实际少几张（一张都没取回时开关仍是开的）。
- **[x] ① 已修复** — `b2ff732c08`：统计失败张数，取完后 SnackBar 提示「有 N 张原截图没能取回，未附上」（新 key `feedback_reopen_shots_failed`，经 i18n_sync 加 + slang 生成）；一张都没取回时开关回到关。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_pages_test.dart`「BUG-3242 重新提交带原截图：有张取不回时提示用户…」（服务端桩 s1 回 503；未修复时红）。
- **备注**：
