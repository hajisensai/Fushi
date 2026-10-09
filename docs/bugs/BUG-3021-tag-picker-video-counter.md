## BUG-3021 · 统一标签面板对视频批量操作仍显示本书
- **报告**：2026-10-06（PR #1984 CI 守卫诊断）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_video_page.dart:2043` 将视频批处理迁移到共享标签面板；`fushi/lib/src/media/tags/tag_picker_sheet.dart` 的 `_apply` 对全部宿主调用书籍专用 `batch_tag_added/removed`，中文仍为「本书」。因此真实视频操作会显示错误量词，合集/混合目标也受影响。
- **[x] ① 已修复** — 根据实际完成写入的宿主类型生成反馈：全视频用已有视频文案，全 EPUB/SRT 用书籍文案，游戏/合集/混合用中性「项」。不从原选择数量推算变更数。提交见本文件所在修复提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/tags/tag_picker_feedback_test.dart` 覆盖添加/移除、视频/书/游戏/合集/混合；`fushi/test/pages/home_video_batch_counter_guard_test.dart` 守住页面→共享面板→实际变更类型→文案调用链。
- **备注**：纯反馈文案与分派修复，不改标签写入语义。实际运行结果由 PR 审查汇总记录。
