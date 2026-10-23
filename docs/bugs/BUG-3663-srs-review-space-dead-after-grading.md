## BUG-3663 · 评分后下一张卡「显示答案」空格失灵
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：评分后下一张卡出现时，按空格「显示答案」无反应。
- **真实性**：✅ 真 bug。根因：换卡时 `reclaimAfterFrame`（`srs_review_page.dart` 换卡处）只做 Flutter 内 `requestFocus`；系统键盘焦点仍留在已离屏的 WebView2（`custom_platform_view.dart` 平台视图抢焦点）。修复改为 `requestViewFocusChange` 把焦点拉回 FlutterView。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：根因为推断：未在真机抓焦点验证；以代码路径与行为测试为据。
