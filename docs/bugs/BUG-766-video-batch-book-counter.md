## BUG-766 · 视频页批量删除/打标签文案误用「本书」量詞
- **报告**：2026-07-13（用户：截图 — 视频多选删除弹窗写「确定删除 26 本书？」）
- **真实性**：✅ 真 bug。`home_video_page.dart` 的批量操作复用了书架专用的 i18n key（`batch_delete_confirm` / `batch_delete_success` / `batch_tag_added` / `batch_tag_removed`），其 zh-CN 文案用书籍量詞「本书」（`确定删除 $n 本书？`），但视频不是书，量詞应为「个视频」。根因：`hibiki/lib/src/pages/implementations/home_video_page.dart:397/441/2499/2506` 直接调用书架量詞 key。
- **[x] ① 已修复** — 新增 4 个视频专用 i18n key（`batch_delete_confirm_video` / `batch_delete_success_video` / `batch_tag_added_video` / `batch_tag_removed_video`，经 `tool/i18n_sync.dart --add` 同步全 17 语言，zh-CN/zh-HK/ja 落真值「个视频 / 個影片 / 本の動画」，其余语言英文占位），并把视频页 4 处调用改指向 `*_video` 变体；`dart run slang` 重生成 `strings.g.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_video_batch_counter_guard_test.dart`：① 源码守卫视频页必须调 `*_video` 变体且不得回落到书架量詞 key；② zh-CN 四个 `*_video` 值必须含「视频」且不得含「本书」。
- **备注**：待真机/桌面复测原始失败路径（视频多选 → 删除弹窗读「个视频」）。提交哈希见 PR。
