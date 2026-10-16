## BUG-3433 · 歌词模式 / 插图册每次打开都在 UI isolate 上整书扫插图
- **报告**：2026-10-15（排查「更新后打开书变慢」时读代码发现；10-15 群里所有者确认歌词插图拖慢开书，问「为什么会有插画表、不应该只加载需要的吗」。不是录屏用户的成因，那条是 BUG-3369）
- **真实性**：✅ 代码路径确认、未真机测时。`_prepareLyricsIllustrations`（`fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart`，b32be24545 插图功能引入）在第一个 await 之前同步读 `book.images`（`packages/fushi_engine/lib/epub/epub_book.dart` 的 `images` getter：逐章同步读文件 + `parseChapterHtml` 整章解析 + 扫 DOM），整本书跑在 UI isolate 上。上次停在歌词模式的有声书开书时自动进歌词模式（9880325ff1 按书记忆歌词模式），正好落在首章就绪前后，长篇卡界面。插图册入口 `_openGallery`（`reader_fushi/chrome.part.dart`）同款；书架插图库 / 兄弟卷（`parseVolumeBookForPeek`）在 isolate 里，但每次打开也整书重扫。
  - 插图表本身是需要的：歌词模式要知道全书每张图的位置，播放走过时弹出、并按当前位置定「已听到」基线。显示侧已按尺寸降采样解码当前一张（`ResizeImage`），与正文 WebView 读的是同一份盘上文件；慢在扫描，不在图片内存。
- **[x] ① 已修复** —
  - 扫描挪出 UI isolate：`_loadBookImagesOffUiIsolate`（`reader_fushi_page.dart`）在后台 isolate 取插图表，`EpubBook.adoptImages` 回填缓存；歌词插图与插图册两处入口改走它，await 后重查 mounted / 代次。
  - 插图表落盘缓存：`packages/fushi_engine/lib/epub/epub_image_index_cache.dart` 的 `loadEpubImagesWithCache`——缓存在 `<support>/epub_image_index/<sha1(解压目录)>.json`，按章节文件大小 + 修改时间 + 扫描版本号判有效，命中直接读回、不再解析 XHTML；章节文件换掉（在线小说占位页 → 正文）自动重算；读写失败当未命中；无盘上章节的书不缓存。不放进解压目录：解压目录会被重打包成 .epub 发给同步对端、整树进备份。阅读器（歌词插图 / 插图册）与书架插图库、兄弟卷（`parseVolumeBookForPeekOffUi`）共用同一份。改 `EpubBook.images` 扫描语义必须给 `kEpubImageIndexCacheVersion` 加一。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_image_index_cache_test.dart`（首扫写缓存、同大小同修改时间换内容后仍读旧结果=证明命中不重扫、章节文件变更失效、损坏缓存退回现算并重写、无盘上章节不缓存、缓存不在解压目录内且按书区分、指纹带版本号）；`fushi/test/epub/epub_image_list_test.dart`（`adoptImages` 跨 isolate 往返）；`fushi/test/pages/reader_illustrations_off_ui_isolate_guard_test.dart`（两处入口不同步读 `book.images`）。
- **备注**：未真机测量开书省下的时间。
