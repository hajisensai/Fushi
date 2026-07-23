## BUG-1008 · 标签筛选下 SRT 命中仍显示无匹配空态且丢失下拉刷新
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：✅ 真 bug（代码路径已验真）。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1219-1261`：`hasActiveFilter && epubBooks.isEmpty` 特殊分支里，SRT 有声书命中筛选并已渲染成网格（1232-1243）后，底部仍**无条件**渲染 `t.tag_no_books_for_filter`「没有书籍匹配所选标签」（1244-1256）——结果与空态文案同屏自相矛盾。该分支还丢失了主分支才有的 `RefreshIndicator`（1268）、合集横排行与书库概览。
- **[x] ① 已修复**（PR#334，随书籍模块 UI 重构落地）——`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1206-1226`：删除整个 `hasActiveFilter && epubBooks.isEmpty` 特殊分支，筛选态与常态统一走下方主分支组装（shelfGroups 已能承载纯 SRT 命中）；空态判定扩到看**全部**会渲染成卡的列表（`epubBooks/srtBooks/remoteBooks/remoteSrtBooks` 全空）才落 `tag_no_books_for_filter`。RefreshIndicator / 合集横排行 / 书库概览随主分支恢复。特殊分支消灭。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_shelf_tag_filter_empty_state_test.dart`：真 DB 种 1 本带标签 SRT + 0 命中 EPUB，开筛选断言不出现 `tag_no_books_for_filter` 且存在 RefreshIndicator。
- **备注**：巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 书籍模块；计划随书籍模块 UI 重构 PR 一并修复。
