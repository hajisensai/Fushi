## BUG-3243 · 反馈人详情页关联 chip 对方不在本机时可点但没反应
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_common.dart` `FeedbackRelationLinks`（原 :262-268）一律画成 `FushiActionChip`，而反馈人详情页的 `_openRelated`（`feedback_detail_page.dart` 原 :205-207）在对方不在本机清单（别的设备提交、本机没 ticket）时直接 return——看起来能点，点了没反应。
- **[x] ① 已修复** — `430fa1121a`：`FeedbackRelationLinks` 加 `canOpen` 判据，打不开的那条画成不可点的 `FushiTag`；反馈人详情页传 `_canOpenRelated`（本机有 ticket 才算）。处理台详情页不传，开发者全都能看。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_pages_test.dart`「BUG-3243 反馈人详情：关联的那条不在本机…画成不可点的标签」（未修复时红）。
- **备注**：
