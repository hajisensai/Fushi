## BUG-893 · 阅读统计「收藏语句」计数恒为 0
- **报告**：2026-07-18（用户：mamit）。反馈原文：「Favorited sentences is 0 even though I added a bunch」——书内确实加了多条收藏，统计页却显示 0。
- **真实性**：✅ 真 bug（写入端/读取端契约错配）。
- **[x] ① 已修复** — 见「修复」。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/favorited_sentence_stats_bug893_test.dart`（分桶回退逻辑 + 写入/读取两端源码守卫）。
- **备注**：真机复测：书内收藏若干句 → 统计页「收藏语句」今日/本周/全部应非 0（含修复前已存的无 dateKey 收藏）。

### 根因
书内收藏语句的写入端与读取端对 `dateKey` 契约不一致：
- **写入**：`hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart` `_toggleFavoriteSentence`
  （旧行 1937-1946）构造 `FavoriteSentence` 只填 text/bookTitle/chapterLabel/createdAt/bookKey/
  sectionIndex/normCharOffset/normCharLength，**没传 `dateKey`** → 恒为 null。（对比：视频收藏
  路径 `video_hibiki/lookup_favorite.part.dart` 早已带 `dateKey: statTodayKey()`。）
- **读取**：`hibiki/lib/src/pages/implementations/reading_statistics_page.dart`（旧行 137-145）
  分桶收藏语句时 `.where((s) => s.source != video && s.dateKey != null)` —— 用 `dateKey != null`
  过滤，把所有书内收藏（dateKey 恒 null）**全部滤掉** → 今日/本周/本月/**全部**桶都恒为 0。

### 修复
- **写入端补 dateKey**（`chrome.part.dart`）：`FavoriteSentence(... dateKey: statTodayKey())`，与视频
  收藏路径口径一致，source 用默认（书籍）。
- **读取端回退 createdAt**（`reading_statistics_page.dart`）：去掉 `dateKey != null` 过滤，分桶键改
  `s.dateKey ?? statDateKey(s.createdAt)`。`createdAt` 恒非空，**修复前已存的无 dateKey 收藏也按
  创建日归桶**（否则用户既有收藏仍显示 0）。两端双向修复。
- 提交：见下方 commit。
