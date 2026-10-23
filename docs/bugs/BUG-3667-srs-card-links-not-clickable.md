## BUG-3667 · 卡片内超链接无法点击
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：卡片内的超链接点不开。
- **真实性**：✅ 真 bug。根因：`kSrsCardLinkScript`（`srs_card_face.dart` 约 283-298 行）对所有 `<a>` 做 `preventDefault`，只放行 `fushi://source`，普通外链被吞。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart、fushi/test/srs/srs_card_face_shell_test.dart`
- **备注**：无。
