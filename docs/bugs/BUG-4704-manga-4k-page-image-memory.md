## BUG-4704 · 漫画阅读器打开 4K 页图卷内存暴涨闪退
- **报告**：2026-11-15（应用内反馈：HONOR YLP-W00 平板，Android SDK 37，3.3.0 正式版；「打开 4K 图集后闪退」「图片加载太激进」；日志 ApplicationExitInfo reason=CRASH，MangaFushiPage / MangaSeriesPage 时 RSS 955 MB～1.8 GB）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/manga/manga_overlay_html.dart:718`（develop 3823eaa74c9）页图 `<img src>` 直指原图；`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_interceptRequest` 本地分支 / 会话分支把盘上原图原样交给 WebView，与显示尺寸无关）
- **[x] ① 已修复** — 按显示尺寸降采样：页面 JS 按每页排版宽度 × DPR × 缩放档（1/2/4/8，只对屏上页升档）算出像素宽挂 `fit=<w>`；拦截器经 Rust `ffc_image_fit_jpeg`（解码含 EXIF 方向、面积平均缩放、JPEG q90 4:4:4、灰度源单通道）在后台 isolate 串行转码，48 MB 字节 LRU；省不到 36% 像素 / GIF / 带 alpha / 在线直读章（尺寸是占位）一律给原图（分支 pr/manga-image-memory）
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_page_fit_test.dart`（尺寸规划、串行 + 去重 + LRU、生成文档 data-src、node 跑真实 `_refitPage`）；`native/fushi_compute/src/image.rs` 三个 `fit_jpeg_*` 单测；`fushi/integration_test/manga_4k_memory_itest.dart`（真机，宿主把 4K JPEG 放到 `<外部存储>/manga4k/` 后跑，焦点驱动翻完整卷，判 RSS 增长 < 350 MB、当前页取的是降采样图、放大后换高档图）
- **备注**：MangaSeriesPage 1.8 GB 那段与整卷 OCR 任务（`_syncOcrJob`）同时出现，属 OCR 域，不在本修复内；系列页封面早已走 `ResizeImage`（720px）。

### 根因

阅读器把整卷页图放进同一个 WebView 文档。3840×5400 的页解码后约 83 MB（RGBA），Android
WebView 在渲染进程（CPU 解码副本）和 app 进程（GPU 纹理，meminfo Graphics/EGL）各留一份，
再乘 ±2 跨页预热和已看过的页。屏幕根本用不到这么多像素：Xiaomi Pad 5（1600×2560，DPR 2.125）
单页只需约 1600 物理像素宽。

真机 A/B（Xiaomi 21051182C，Android 16，40 页 3840×5400 JPEG，跨页模式逐页翻完）：

| 构建 | 打开后 RSS | 峰值 RSS | 增长 | meminfo Graphics 峰 | WebView 渲染进程 |
|---|---|---|---|---|---|
| 修复前 | 714 MB | 1230 MB（VmHWM 1239） | 516 MB | 464 MB | 405～554 MB |
| 去掉 `img.decode()` 预解码（探针） | — | — | 381 MB | 473 MB | — |
| 只保留 ±3 页 src（探针） | — | — | 382 MB | 472 MB | 400～520 MB |
| 同页 1920×2700 原图 | — | 824 MB | 227 MB | 345 MB | 220～244 MB |
| 修复后 | 624 MB | 822 MB（VmHWM 923） | 198 MB | 325 MB | 约 170 MB |

预解码与常驻窗口都不是主因，源图像素数才是：内存随源像素线性走。
