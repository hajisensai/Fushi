## BUG-4903 · 首页（桌面）「继续」右侧卡被窗口切掉一半、标题拼接成「Re：ゼロ…1<Re：…」
- **报告**：2026-11-15（用户：拼贴审查设计稿 #home-desk H4「继续区右边的卡片被窗口切掉一半（FX、The Ap…）；
  VINLAND SAGA 没有封面；标题拼接成『Re：ゼロ…1<Re：…』」）
- **真实性**：✅ 真 bug，三处根因：
  1. 切边：`fushi/lib/src/pages/implementations/home_dashboard_page.dart:1884`（upstream/develop 行号）用
     `FushiCoverBlockStrip`「主块 + 两行半高卡横滑」，横滑条宽度不按可用宽度算列，最后一列总是被视口切在窗口边。
  2. 没封面：同文件 `_orientedBlock`（:2083）对横图（截帧 / 剧照）走横版摆法——整张图铺成色块背景渐入、前景没有
     封面，小块里看起来像没有封面。
  3. 标题拼接：不是代码把两段标题拼起来，而是数据本身。安装版库里这本书 `epub_books.title` 实为
     「Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)」（Kindle / BookWalker 的
     「正文 卷号<系列名> (文库名)」写法），书族显示出口
     `fushi/lib/src/media/sources/reader_media_source.dart:50`（`getDisplayTitleFromMediaItem`）与
     `fushi/lib/src/media/display_title.dart:81` 只去哈希后缀、把注记原样当显示名，一行宽度下就成了
     「Re：ゼロ…1<Re：…」。
- **[x] ① 已修复** — ① 桌面「继续」换成 `HomeContinueGrid`（`home_collage_widgets.dart`）：首块 + 两行半高块，
  列数按可用宽度算（`homeContinueGridColumns`），每块完整落在内容区，放不下的进分区标题的「全部 ›」
  （`HomeContinueAllPage`）。② 首页拼贴「继续」视频一律竖版摆法（`_continueBlock(portraitOnly: true)`），没有
  海报时剧照经 `PortraitCoverImage(cropMismatch)` 裁成竖版。③ 新增 `stripStoreSeriesAnnotation` /
  `cleanBookDisplayTitle`（`display_title_store_series.dart`）：系列名是正文前缀时去掉 `<系列名>` 与其后的
  `(文库名)`，两处书族显示出口改调它（只改显示，身份原名不动，override 原样）。提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_collage_widgets_test.dart`「HomeContinueGrid（H4）」组：
  820 / 1000 / 1366 / 1920 宽下每块都在内容区内、只画首块 + 两行、首块是 hero；
  `fushi/test/media/display_title_store_series_test.dart`：用户库里的真实书名与不该动的写法。
- **备注**：`parseBookSeriesKey`（`packages/fushi_engine/lib/media/collections/book_series_key.dart`）对这种
  「卷号<系列名> (文库名)」写法也认不出系列（先剥的是 `(MF文庫J)`、尖括号前的卷号没被读到），导入时不会自动
  归成合集——属引擎线，未改，列为跨线请求。真机像素未复测。
