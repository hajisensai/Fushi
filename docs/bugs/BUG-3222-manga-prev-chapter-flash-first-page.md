## BUG-3222 · 翻回上一章先闪上一章开头再跳到末尾
- **报告**：2026-10-09（用户：反馈处理台 qMRtA75fhO：「翻回到上一章时它会先闪回一下上一章的开头再闪到末尾」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`（upstream/develop）`_switchToChapter` 先按章级进度（通常第 0 页）`_openShelfChapter` 装载、窗口文档画出来之后 `:3181` 再 `_jumpToPage(pageCount)`（slide 动画还会扫过去）。另外 `manga_overlay_html.dart` 的 `#manga-root` 首帧是 `transform:none`，要等 load / 双 rAF 后 `_reanchor` 才投影到落点——LTR 下首帧画的是窗口里 DOM 最左的跨页（开头）。
- **[x] ① 已修复** — `_openShelfChapter(landOnLastPage:)` 把 `kMangaLandOnLastPage`（越界即末页）作为起始页交给装载链，由页数已知的 `_presentPayload` / 直读落点 `clamp(0, n-1)` 钳到末页（直读顺带先取的就是末页）；去掉装好后的二次 `_jumpToPage`，只 `_recordProgress()` 记落点；窗口文档把落点跨页的 strip 槽位直接写进 `#manga-root` 的内联 `transform:translateX(-k*100vw)`，首帧即落点。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_chapter_crossing_test.dart`（`_switchToChapter` 不再 `_jumpToPage`、起始页钳位接线；文档首帧 transform 指向末跨页（LTR -500vw / RTL -0vw）；落在末页时第 0 页 `loading=lazy`、末页 eager）。
- **备注**：没有能跑真 WebView 的 widget 层手段，「整个过程从未渲染第 0 页」由「文档首帧就是末跨页 + 装载后无二次跳页」两条组合保证；真机未连，未在设备上复测。
