## BUG-3670 · 查词弹窗「新卡」与「跳转」去同一页面
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：查词弹窗里「新卡」与「跳转」两个按钮去往同一个页面。
- **真实性**：✅ 真 bug。根因：制卡目标为 SRS 时两颗按钮都走 `srsPushNoteEditor`（`popup.js` 约 298-340 行；`srs_mining.dart` `openWordInAnki` 约 981 行）。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js`
- **备注**：无。
