## BUG-3666 · 只有一句例句却出 5 个音频按钮、未开自动播放全播
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：只有一句例句却出现 5 个音频按钮；没开自动播放时也全部被播放。
- **真实性**：✅ 真 bug。根因：按整张答案 HTML 收集媒体（`srs_review_page.dart` → `srsCardMediaNames`），把释义区与模板重复容器一并算入；`[sound:]` 不去重；缺失文件时整组停播（`srs_card_autoplay.dart`）。另修复多段单词音频重复 key 崩溃。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：无。
