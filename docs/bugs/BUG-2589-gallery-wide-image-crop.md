## BUG-2589 · 插图册横版插图被裁成竖版卡片，书架端「查看插图」与阅读器内插图册两套实现
- **报告**：2026-09-18（用户：截图——插图册里一张横版双页图被塞进竖版格子，只剩中间一条；同时要求砍掉书架端「查看插图」的旧样式，直接用阅读器内插图册同一套）
- **真实性**：✅ 真 bug。根因两处：
  1. `fushi/lib/src/reader/reader_gallery_page.dart` 网格用 `SliverGridDelegateWithFixedCrossAxisCount(childAspectRatio: _kCardAspectRatio /* 0.72 */)` + 缩略图 `BoxFit.cover`——每张卡都是竖版比例，横版（宽 > 高）的双页插图只能裁掉两侧。布局是解析式的（列数 / 行高推滚动偏移），页面根本不知道每张图的宽高，没有任何一处能让横版图占更宽的格子。
  2. `fushi/lib/src/pages/implementations/illustrations_viewer_page.dart`（书架端「查看插图」）是另一套实现：自己 `listSync` 扫目录、自己的 `GridView` + `FushiCard` + `Image.memory(fit: contain)`、自己的 `_FullScreenGallery`（PageView + 复制 / 分享 + 手柄），以及自己的进度索引 `illustration_progress_index.dart`。同一本书两处长得不一样、解锁交互不一样、横版图也各裁各的。
- **[x] ① 已修复** — 见本 PR 分支提交：
  - 新增 `lib/src/reader/illustration_aspect_probe.dart`：开页时在 isolate 里只读文件头（PNG / JPEG / GIF / BMP / WebP；JPEG 先读 64 KiB，走不到 SOF 再整文件回读）拿宽高比；`ReaderGalleryPage` 据此把横版图装成占两列的槽位（`_GalleryLayout._packSection` 按阅读顺序装填，放不下另起一行；自定义 `_SlotGridDelegate` 让 sliver 网格与滚动定位读同一份槽位表；键盘 ↑/↓ 按槽位几何找最近列）。探测落定时若用户还没动滚动条，按新布局重新定位到当前章。
  - 书架端 `IllustrationsViewerPage` 改成薄装载壳：isolate 解析结构（复用 `parseVolumeBookForPeek`）+ 读 `reader_positions` / `revealed_images`，然后直接渲染 `ReaderGalleryPage`；`currentChapter` 改为可空（没有位置行 = 从没打开过 → 不按进度遮、不出定位键）；「跳到此插图」= pop 后经 `openMedia(initialBookmarkJump:)` 按章开书。
  - 缩放查看 / 复制 / 分享 / Windows 右键菜单抽成 `lib/src/reader/illustration_zoom_viewer.dart`，阅读器正文、阅读器插图册、书架端三处共用；删除 `illustration_progress_index.dart` 与旧 `_FullScreenGallery`；i18n 删 `no_illustrations_found` / `image_page_counter`。
- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/illustration_aspect_probe_test.dart`：五种格式合成头 + 真 PNG / JPEG + SOF 在 64 KiB 之后的整文件回读。
  - `fushi/test/reader/reader_gallery_page_test.dart`「横版插图占两列……」：真 PNG 文件 + isolate 探测，断言横版卡 = 两格宽 + 间距、同行阅读顺序、放不下另起一行、↑/↓ 按几何找邻居；另两条覆盖 `currentChapter: null`。
  - `fushi/test/pages/illustrations_viewer_unread_blur_test.dart`：书架端真 EPUB 目录 + 真 Drift，按进度遮 / 读完不遮 / 没读过不遮且无定位键 / 揭开落库 / 跳转回调先 pop。
  - 源码守卫：`reader_gallery_guard_test.dart`（书架端必须直接用 `ReaderGalleryPage`、不得再长第二份网格 / 查看器 / 进度索引；横版图槽位与探针）、`reader_image_actions_guard_static_test.dart`（复制 / 分享 / 菜单只有共享的一份）。
- **备注**：横版判据是宽 > 高，占 `min(2, 列数)` 列，一列时退回占一列。SVG 等认不出头部的格式按竖版处理。
