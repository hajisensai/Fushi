## BUG-4260 · 在线漫画「全部页面」网格不显示缩略图，已看过的页也没有
- **报告**：2026-11-09（用户：应用内反馈 3VwZimDVBE，Android 3.3.0-debug.24478）
- **真实性**：✅ 真 bug。在线直读章打开时 payload 的 url 是不带扩展名的占位名
  `images/<章目录名>/page-000001`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` 原 :2645-2656），
  `_imagesDir` 却是会话缓存目录 `session.directory`（同文件 :2668）；会话真正落盘的是
  `session.directory/page-000001.jpg`（`fushi/lib/src/media/manga/mihon/online_manga_reader_session.dart:300`，
  文件名由 :380 `onlineMangaStreamPageFileName` 生成，带扩展名）。`_pageThumbnail`（原 :6129）走
  `resolveMangaPageImage` → `resolveMangaResource` 按占位 url 拼路径，文件永远不存在，在线直读章每一格都返回 null，
  已缓存的页也一样。
- **[x] ① 已修复** — 新增 `MangaFushiPage.cachedMangaPageImage`（在线直读会话只认 `session.cachedFilePath`，
  其余照旧按 manga.json 解析），`_pageThumbnail` 与 `_updateCurrentPageImagePath` 共用；占位 url 收成
  `MangaFushiPage.streamingPageUrl` 单一出处。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/online_manga_page_thumbnail_bug4243_test.dart`
  （真 `OnlineMangaReaderSession` 取一页后断言：旧路径按 url 解析为 null、新路径给出已落盘文件；没取到的页 null 且不发请求；本地卷不回归）。
- **备注**：没取到的页仍画页码占位、不为缩略图发网络请求（`manga_reader_page_grid.dart:26` 设计如此）；
  「整章都要能预览」需要预取，属产品决定，未做。设备肉眼复测待补。
