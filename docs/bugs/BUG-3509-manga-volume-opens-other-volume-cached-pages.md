## BUG-3509 · manga-volume-opens-other-volume-cached-pages
- **报告**：2026-10-17（用户：Android 漫画合集「志乃と恋」1–4 卷，网格封面正确，点第 1 卷进入阅读器显示的是第 2 卷内容（首页是卷 2 封面））
- **真实性**：✅ 真 bug（读代码定性，未在真机复现）。页图 URL 只有 `https://manga.local/img/<相对路径>?v=<代次>`，没有卷身份；代次 `_pageSessionGeneration` 是阅读器实例字段，每开一次阅读器都从 0 数、开书后恒为 1（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `_presentPayload` 内 `_pageSessionGeneration++`）；拦截响应带 `Cache-Control: max-age=3600`。两卷页图同名（导入落 `page_000000.*` / 出版来源同为 `001.jpg`）时，先开过卷 2 再开卷 1，首页 URL 一字不差，WebView 直接复用卷 2 的缓存页图。BUG-2884 的 `?v=` 修法只覆盖同一阅读器内换章。合集页 index 错位、bookKey 撞车两个方向已沿代码排除（打开走 `entryKey`，bookKey 由标题 sanitize 得来、两卷不同）。
- **[x] ① 已修复** — 代次改取进程级单调计数 `_pageSessionGenerationCounter`；URL 另挂卷作用域 `s=<mangaPageScope(imagesDir)>`（FNV-1a 短哈希，同卷恒同、保住同卷缓存复用），跨进程也不撞。
- **[x] ② 已加自动化测试** — `fushi/test/pages/manga_fushi_page_pure_test.dart`（两卷同名页、同代次 URL 必须不同；同卷作用域稳定）；`fushi/test/media/manga/manga_chapter_switch_reload_guard_test.dart`（代次必须是进程级、URL 必须带作用域）。
- **备注**：WebView 缓存层（内存 / 磁盘）未在真机核实；决定性验证是 Android itest：两卷同名不同尺寸页图，先开 B 再开 A，断言可见页 `naturalWidth` 为 A。
