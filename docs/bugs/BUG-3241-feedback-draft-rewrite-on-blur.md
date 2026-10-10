## BUG-3241 · 反馈草稿在桌面主窗每次失焦都整份重写（含截图）
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_compose_page.dart` `_flushDraft`（原 :189-213）：`AppLifecycleListener.onStateChange` 对每个非 resumed 状态都立刻落盘，桌面主窗一次失焦就是 inactive（切走再 hidden / paused 还会连发），每次都按当前表单整份重写——`FeedbackDraftStore.write` 先写 `draft.tmp/`（最多 3 张截图各一个文件 + flush）再删旧目录、改名，内容一个字没变也照写；空表单时同样每次 `clear()`。输入框选区变化触发的防抖保存也是同样的空写。
- **[x] ① 已修复** — 提交「fix(feedback): skip draft writes when nothing changed」：页面记住磁盘上草稿此刻的内容（读草稿后即知；写失败则置为未知），落盘前逐字段比较（截图按引用），没变就不写 / 不 clear。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_draft_test.dart`「BUG-3241 内容没变时失焦 / 进后台不重写草稿」（草稿目录里放记号文件，两轮失焦后记号仍在；改了内容再失焦即重写；未修复时红）。
- **备注**：
