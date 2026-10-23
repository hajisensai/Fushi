## BUG-3665 · 卡上视频不能放大、与例句按钮重复出声，重播导致重音
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：卡上视频片段不能放大；并且与例句按钮重复出声，重播导致重音。
- **真实性**：✅ 真 bug。根因：例句按钮走 `srsSoundPlayerProvider` 独立一路（`srs_fushi_card_view.dart` `_play`），与视频片段同一个 webm 双路发声；片段无放大入口。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：无。
