## BUG-2513 · 漫画作品页加入书架后无法取消
- **报告**：2026-09-13（用户：「加入漫画书架，应该可以取消。取消并且删除这本书」）
- **真实性**：✅ 真 bug。作品页在库态把同一个按钮渲染成不可点的「已加入漫画书架」（`fushi/lib/src/media/manga/library/manga_series_page.dart` `_buildActions`，`onPressed: inLibrary || _busy ? null : …`），没有任何移出入口；只能回书架长按删。
- **[x] ① 已修复** — 在库态按钮改成「移出漫画书架」（`manga_series_remove_from_bookshelf`），复用书架长按删除的同一个确认框 `ReaderHistoryDeleteDialog`（披露 + 「同步删除」范围 + 记住选择），再走同一条 `ReaderFushiSource.deleteBook`（`scope` 按用户选择传播）（DB 行 + 解压目录里已下载章节 + 章节状态 + 下载任务行，`deleteEpubBook` 一个事务级联），删前先取消本书的 OCR（`MangaOcrJobRegistry.cancel` 现在连排队的一起放弃——只停正在跑的话链尾会在目录删掉后把下一个开起来）与排队/进行中的下载任务（用 `remove` 等正在飞的真停，`cancel` 只置标志就返回、worker 还在写目录会撞 errno 32 留孤儿目录）。删完页面**不关**、退回未入库态（条目与章节列表还在手上，可立刻重新加入或换源）。书架经 `_epubBookKeysProvider` 订阅自动重算，不用手动刷。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_series_page_remove_from_shelf_test.dart`（在库态只出「移出」不出「加入」；确认后 DB 行、解压目录（含已下载章）消失、页面退回「加入」且章节列表仍在、下载状态位清空；确认框取消则什么都不删）。
- **审查返工**：cancel 不等真停 / OCR 排队者漏杀 / `siblingOf` 裸异常 / 删除范围固定本地 四处按审查修正；`ReaderHistoryDeleteDialog` 去掉 `@visibleForTesting`（第二个生产消费方）。
- **备注**：`deleteBook` 把有声书持久目录清理与解压目录清理放在同一个 try 里，前者抛（如 path_provider 缺实现）会带掉后者——生产环境 path_provider 总在，只影响测试（测试里 mock 了该 channel）。
