## BUG-634 · 阅读器每页列数(pageColumns)不生效

- **报告**：2026-07-08（用户：Windows 阅读器竖排书截图，进度 189/94990，改「每页列数」页面列数不变）
- **真实性**：✅ 真 bug，但**已在当前 origin/develop 根因修复**（用户构建过旧）。修复由三个先行 commit 落地：`2ebaed004`（CSS 子列宽均分）、`eeca34e97`（JS pageStep 反推）、`339a433be`（相邻页泄露覆盖条）。核心根因 `hibiki/lib/src/reader/reader_content_styles.dart:219`（旧实现只发 `column-count:N` 却把 `column-width` 钉死在整页 content-box → CSS multicol 规范下实际列数 = min(N, floor((content-box+gap)/(column-width+gap))) = min(N,1) = 1，N 被整页列宽压回 1 列）。

### 根因

「每页列数」(pageColumns) 全链在 develop 上均已接通并根因修好，本次沿真实路径逐层验真：

1. **写穿**：UI `settings_schema_reading.dart:192`（`setTtuPageColumns(v.round())`）与快捷设置 `reader_quick_settings_sheet.dart:220` → `ReaderSettings.setPageColumns`（`reader_settings.dart:317`）→ `_set('ttu_page_columns')` 落 Drift `preferences` 表。✅ 有写穿守卫。
2. **live-update**：pageColumns 是 layoutKey（`reader_quick_settings_sheet.dart:240`）→ `_reloadLayoutLive` → `onReloadChapter`＝`chrome.part.dart:1489 _reloadWithCurrentSettings`：清 `_sanitizedCssCache` / `_invalidateStyleCache` → `_loadChapterDirectly` 全量重载当前章，用新 pageColumns 重生成 CSS 并重注入竖排 `--reader-viewport-height`。✅ 不用重开书。
3. **CSS 应用（根因修复所在）**：`reader_content_styles.dart:227 columnWidthForColumns` 在 N≥2 时把 `column-width` 均分成子列宽 `(content-box−(N−1)·gap)/N`（横排基准=宽 `:218`，竖排基准=`verticalColumnWidthCss` 高 `:212`），配 `column-count:N`（`:301`）+ `column-fill:auto`（`:669`）。代数上 floor((content-box+gap)/(subW+gap))==N，浏览器正好排下 N 列。
4. **JS pageStep**：`reader_pagination_scripts.dart:1741` getScrollContext 页步 = columnCount·(usedColW+gap)，columnCount 回读为 'auto' 时从几何反推 N（不塌成 1），保翻页网格对齐、无相邻页泄露。
5. **竖排语义（用户命中面）**：竖排 vertical-rl 的 multicol 列沿 **inline 轴（自上而下 Y）** 推进（不是横排的 X 轴）；develop 的竖排基准用 `verticalColumnWidthCss` 高，与该轴向成对。**headless Blink 实测确认**：竖排 N=2→每屏 2 列（列首 top=0,408）、N=3→3 列（top=0,272,552）；横排 N=2→2 列（left=24,512）、N=3→3 列（left=24,344,672）；N=0/1→1 列。改 N 真变每屏列数。

结论：**当前 develop 上「每页列数」横排竖排都真生效**。用户症状来自其安装的构建早于上述三个 commit（Jul 7–8 刚落地）。

### 修复

- **[x] ① 已修复** — 根因修复已在 origin/develop 落地（无需本次再改阅读器代码，重做会引回归风险）：
  - `2ebaed004` fix(reader): make per-page column count actually take effect — `columnWidthForColumns` 子列宽均分（`reader_content_styles.dart:74/227`）。
  - `eeca34e97` fix(reader): make per-page pageStep robust when WebView misreads columnCount as 'auto' — 几何反推 pageStep（`reader_pagination_scripts.dart:1741`）。
  - `339a433be` fix(reader): hide multi-column adjacent-page leak in padding band — `html::before` 覆盖条（`reader_content_styles.dart:701`）。
  - 本次沿真实路径复验写穿 / live-update / CSS / JS / 竖排轴向五层，均已正确接通，无残留缺口。
- **[x] ② 已加自动化测试** — 既有 CI 可跑的字符串守卫 + 本次新增渲染层实证守卫：
  - 既有（`hibiki/test/reader/reader_content_styles_test.dart`）：横排/竖排 `column-count:N`+子列宽均分、N=0 字节等价、`column-fill:auto`、`columnWidthForColumns` 均分代数、写穿 DB —— 但这些是**纯字符串断言**，测不出浏览器真渲染 N 列。
  - 新增（`tool/reader_pitch_headless/columns_per_page_proof.mjs`）：headless Chrome（= Android WebView / Windows WebView2 同一 Blink）复刻真实几何、逐字符量 multicol 列首坐标、**实测每屏列数 == N**，横排+竖排 × N=0/1/2/3 共 8 例全 PASS。这层直接封住「字符串对但渲染不对」的盲点；旧几何（整 content-box 当列宽）在此守卫下 N≥2 会得 1 列 → FAIL（有牙齿）。CI 跑不到真 WebView，故为本机 harness 守卫（与 `band_period_probe.js` / `multicol_screenshot_proof.mjs` 同类）。

- **备注**：
  - 与旧 decision 提及的 BUG-588「页边距泄露相邻页文字/覆盖条」是**另一问题**，其修复即 `339a433be`，已在 develop；本条专指「列数改了不变」，两者独立。
  - 用户侧行动建议：更新到含上述三个 commit 的构建即生效，无需任何设置迁移（`ttu_page_columns` key 不变）。
  - 未改任何阅读器 Dart 代码（避免重做已工作的修复引回归）；本条产物 = 本 BUG 文档 + 新增渲染层 headless 守卫。

### 第三次复诉 · 真 WebView2 离屏闭环量测（2026-07-10）

用户第三次报「每页列数不生效」。此前所有「列数真生效」证据都是 **headless Chrome**
（`tool/reader_pitch_headless/columns_per_page_proof.mjs`）或纯字符串守卫，**从未在真
WebView2 引擎上量过** —— headless Chrome 与用户实际渲染用的 fork
`flutter_inappwebview_windows`（WebView2/Edge Chromium）不是同一构建。本次首次在**真
WebView2** 上把真实 `ReaderContentStyles.css` 注进 live `InAppWebView`、回读
`getComputedStyle`/`getBoundingClientRect` 闭环量测。

Harness：`hibiki/integration_test/desktop_reader_columns_dom_test.dart`
（`tool/run_windows_itest.ps1` 离屏跑，窗口 1265x682，All tests passed）。

真 WebView2 实测（每页列数 N 真渲染 N 列 + JS pageStep == 真页步）：

| 模式 | N | computedColumnCount | computedColumnWidth | 首屏列带 | 真页步 | JS pageStep |
|---|---|---|---|---|---|---|
| horizontal-tb | 1/2/3 | 1/2/3 | 1214 / 596 / 390px | 1/2/3 | 1237 | 1236.4（各 N 恒定）|
| vertical-rl | 1/2/3 | 1/2/3 | 660 / 319 / 205px | 1/2/3 | 682 | 682（各 N 恒定）|

- `computedColumnCount` / `columnWidth` 在真 WebView2 均回读为**干净数字**（不是 'auto'）——
  eeca34e97 担心的「WebView 回读 columnCount='auto'」在 WebView2 上未出现，快路径直接命中。
- JS pageStep == 真页步（差<1px），**无相邻页泄露**。
- 图片夹取（BUG-679）真引擎复验：横排 N=2、子列 596px，无 `_imageMaxBox` clamp 时 1200px 宽图
  渲染 1200px（溢出 2x 盖住相邻列 = 用户「图片挤压」症状）；把 `--hoshi-image-max-width` 设为
  `getComputedStyle(body).columnWidth`（=596.193px）后夹到 596px。证明 clamp 承重且在真引擎生效。

结论（更强证据下重申）：**develop（e096c594a）上每页列数 + 图片夹取在真 WebView2 均正常**，
三个先行 commit + BUG-679 图片修复在真引擎全部有效。第三次复诉最可能是用户构建早于
BUG-679 修复日（2026-07-09），或图多/短内容页的视觉错觉。**未改任何阅读器代码**（避免对已工作
的几何引回归）；本轮产物 = 真 WebView2 离屏守卫 harness + 本节验证记录。证据：
`.codex-test/todo1285-webview2-columns-measurement.md`。
