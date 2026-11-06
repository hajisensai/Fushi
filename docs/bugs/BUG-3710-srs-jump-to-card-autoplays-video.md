## BUG-3710 · 从查词弹窗跳转到卡片视频自动播放
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：从查词弹窗跳转到卡片后，卡片视频自动开始播放。
- **真实性**：✅ 真 bug。根因：`SrsCardFace.autoplayMedia` 缺省为 true（`srs_card_face.dart` 约 63 行），编辑页预览没有传值；缺省改为 false。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：无。
