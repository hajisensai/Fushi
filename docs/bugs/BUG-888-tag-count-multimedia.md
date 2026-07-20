## BUG-888 · 标签管理器对有声书/视频标签显示 0 本
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug — `packages/hibiki_core/lib/src/database/database.dart` 的 `countBooksForTag(int tagId)` 只 COUNT `book_tag_mappings`（EPUB）一张映射表，漏掉 `srt_book_tag_mappings`（有声书）与 `video_book_tag_mappings`（视频）。标签是三种媒体共享的同一标签池（`BookTags`），书卡显示标签走的是分媒体类型的正确查询（`getTagsForSrtBook` / `getTagsForVideoBook`），能显示标签；但标签管理器计数只读 EPUB 表，给有声书/视频打的标签恒显示 0 本。用户给两本**有声书**打了 `Finished` 标签，卡片可见、管理器显示 0。
- **[x] ① 已修复** — `countBooksForTag` 改为对三张映射表各自命中该 tagId 的行数求和（三类媒体互不重叠，直接相加即总书数）。`database.dart` `countBooksForTag`。提交见分支 `worktree-book-completed-status`。
- **[x] ② 已加自动化测试** — `hibiki/test/database/tags_test.dart`：`countBooksForTag sums EPUB + SRT + video`——给同一标签分别挂 EPUB / SRT / 视频各一，断言计数为 3（修复前只返回 1）。
- **备注**：与 BUG-889（完成状态）同一 PR 落地。
