## BUG-3709 · 复习页音频按钮与评分按钮同一行
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：复习页的音频重播按钮与评分按钮挤在同一行。
- **真实性**：✅ 真 bug。根因：`_withBottomReplay`（`srs_review_page.dart` 约 1449-1559 行）把重播键与评分按钮排进同一个 Row。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart、fushi/test/srs/srs_pages_test.dart`
- **备注**：无。
