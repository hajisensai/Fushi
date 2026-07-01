## BUG-501 · TODO-1074 图片章加载慢

- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug。图片章首屏/换章慢、「文本—图片—文本」来回切卡。

### 根因

- **根因 A（主·最高杠杆）：首屏可见性/restore 被 `Promise.all(所有 img onload)` 整页阻塞。**
  `hibiki/lib/src/reader/reader_pagination_scripts.dart` 的 `_sharedInitImages`
  （旧 `:1486-1507`）对每个 `<img>` 挂 `img.onload = mark` 才 resolve 其 Promise；
  `initialize()` 里 `Promise.all(imagePromises).then(...)`（分页 `:2319` / 连续 `:2817`）
  gate 住 `buildNodeOffsets` + restore。整章可见性/定位被最大图的全分辨率读盘+解码阻塞。
  文字章几乎无 `<img>` → `Promise.all` 立即 resolve，故文字快、图片慢。
- **根因 B：图片响应 `Cache-Control: no-cache`。**
  `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的
  `_interceptRequest`（`/epub/` 分支响应头旧 `:155` 恒 `no-cache`）→ WebView 每次换章
  都重读盘 + 全分辨率重解码，来回切同一图重复付出。
- 根因 C（同步 sanitize）/ D（metrics=null 全文重扫）为次要项，本轮不改（见备注）。

### 修复

- **[x] ① 已修复** — commit `5aa5fb524`
  - A：`_sharedInitImages` 改为——每个 `<img>` 加 `loading="lazy"`（gaiji 内联小图除外，
    它们参与文字排版几何须 eager）+ `decoding="async"`；`imagePromises` 恒为空数组
    （restore 不再等未完成图）；block-img 归类改由每张图自己的 `load` 事件补做，补做后
    失效 `paginationMetrics`（与 TODO-627 同源，防漏列误判跳章）。
    `reader_pagination_scripts.dart:1444-1541` 附近。保留 `Promise.all(imagePromises).then`
    编排壳（现空数组立即 resolve），最小改面。
  - B：`webview.part.dart` `_interceptRequest` 尾部按 `mime.startsWith('image/')` 给图片
    响应 `Cache-Control: max-age=3600`（与字体 `:107` 先例一致），HTML/CSS 仍 `no-cache`
    （随样式变化被逐次重 sanitize + 注入 styleTag，缓存会串旧样式）。`webview.part.dart:148-166`。
  - 不破坏：BUG-025 SVG 封面同步 block-img（`querySelectorAll('svg')` 分支未触及，尺寸取
    属性/viewBox 无 onload 依赖）；BUG-007 图片暂停锚点（`isImageOnlyChapter` 在 Dart 侧
    静态解析 EPUB HTML，与 JS `loading`/`decoding` 无关）。

- **[x] ② 已加自动化测试** — commit `5aa5fb524`
  - `hibiki/test/reader/image_chapter_lazy_load_guard_test.dart`：调真生成器
    `ReaderPaginationScripts.shellScript`，断言分页/连续 shell 产物含 `loading=lazy`/
    `decoding=async`、`imagePromises` 为空数组、删除旧 `img.onload = mark` 逐图 gate、
    延迟 `load` 补归类 + 失效 metrics、SVG 封面同步分支不回退。
  - `hibiki/test/pages/reader_image_cache_control_guard_test.dart`：扫 `_interceptRequest`
    语料，断言图片 `max-age=3600`、HTML/CSS `no-cache`、Cache-Control 按 mime 动态取值。
  - 亲跑：12 tests all passed；`reader_chapter_html_cache_test` / `paged_cross_chapter_limit_test`
    回归绿；全量 `flutter analyze` No issues。

- **备注**：根因 C（换章整页 loadUrl 重载 + 主 isolate 同步 sanitize）与 D 的进一步治理
  （in-place 注入换章）改造面大，本轮不做，留后续项。真机 profiling 占比确认留给集成
  owner / 用户。
