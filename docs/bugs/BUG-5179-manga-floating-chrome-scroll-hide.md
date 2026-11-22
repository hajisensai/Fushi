## BUG-5179 · 漫画悬浮底栏：切到条漫一滚动就再也点不出底栏
- **报告**：2026-11-21（应用内反馈 #Yh8ukM6J_i，开发者本人：「点这个按钮以后，回不去了，点击不出来悬浮底栏」——按钮是播放条上的「阅读模式」）
- **真实性**：✅ 真 bug（读代码定位，未在真机复现）。
  - 根因：「滚动收起界面」把悬浮态的临时显隐与 M 键的持久隐藏混成一个状态。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:9392` 收到 `onMangaReaderHide(true)` 调 `_toggleMangaChrome()`（`:8018`）把 `_chromeVisible` 置 false；悬浮态唯一的唤出手段 `_toggleFloatingChrome`（`:2247-2248`）在 `_chromeVisible` 为 false 时直接 return，点击彻底失效。
  - 诱因：JS 端（`fushi/lib/src/media/manga/manga_overlay_html.dart:3660-3672`）把「用户输入后 1200ms 内的 scroll」都算用户滚动，阅读器自己发起的滚动（`__mangaScrollToSpread` 跳页 `:2276`、平滑翻页、有声跟随露出句子 `scrollIntoView`、分镜聚焦、自动滚动）落在一次点击之后就会被当成用户在滚。分页模式不滚动，所以只在切到条漫后出现。
- **[x] ① 已修复** — 新纯函数 `mangaScrollHideEffect`（`manga_reader_chrome.dart`）：悬浮态往下滚只 `hideTransient()`、往上滚不动，绝不改 `_chromeVisible`；固定态维持原来的持久显隐。JS 端把程序滚动收成 `_programScrollTo` / `_syncReaderScrollBaseline`（与缩放锚点回写同一做法），滚完同步 `lastReaderScroll` 基线，不再计入用户滚动。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/manga_reader_chrome_test.dart`（`mangaScrollHideEffect` 2 项）；`fushi/test/media/manga/manga_zoom_scroll_chrome_js_test.{dart,js}`（真 headless Chrome：按键后 `__mangaScrollToSpread` 跳页不回报 `onMangaReaderHide`，2 项检查）；`fushi/test/media/manga/reader/manga_audio_reader_wiring_static_test.dart`（JS 回调经 `mangaScrollHideEffect` 分流的源码守卫）。变异实测：还原后全红，恢复后全绿。
- **备注**：真机未复测新构建。
