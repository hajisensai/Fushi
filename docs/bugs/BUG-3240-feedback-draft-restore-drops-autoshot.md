## BUG-3240 · 反馈提交页恢复草稿时丢掉本次打开自动截的图
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_compose_page.dart` `_loadDraft`（原 :163-165）恢复草稿时 `_shots..clear()..addAll(draft.screenshots)`，把本次打开反馈前自动截的画面（`widget.initialScreenshot`）整个丢掉；那一刻的现场关掉提交页就截不回来，只能「丢弃草稿」才找得回（连带丢掉写好的文字）。原测试把「恢复的是草稿，不是新截图」当作期望钉住，规格（docs/specs/2026-10-08-feedback.md）没有这条约定。
- **[x] ① 已修复** — `51384899f5`：恢复后若还有空位、且草稿里没有字节相同的那张，把本次自动截图接在草稿截图后面（草稿满 3 张时以用户自己挑的为准）。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_draft_test.dart`「写到一半返回…再打开自动恢复」改为断言恢复后共 3 张、第 3 张就是本次的新自动截图（未修复时红）。
- **备注**：
